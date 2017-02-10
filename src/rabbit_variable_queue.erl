%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_variable_queue).

-export([init/3, terminate/2, delete_and_terminate/2, delete_crashed/1,
         purge/1, purge_acks/1,
         publish/6, publish_delivered/5,
         batch_publish/4, batch_publish_delivered/4,
         discard/4, drain_confirmed/1,
         dropwhile/2, fetchwhile/4, fetch/2, drop/2, ack/2, requeue/2,
         ackfold/4, fold/3, len/1, is_empty/1, depth/1,
         set_ram_duration_target/2, ram_duration/1, needs_timeout/1, timeout/1,
         handle_pre_hibernate/1, resume/1, msg_rates/1,
         info/2, invoke/3, is_duplicate/2, set_queue_mode/2,
         zip_msgs_and_acks/4,  multiple_routing_keys/0]).

-export([start/1, stop/0]).

%% exported for testing only
-export([start_msg_store/2, stop_msg_store/0, init/6]).

%%----------------------------------------------------------------------------
%% Messages, and their position in the queue, can be in memory or on
%% disk, or both. Persistent messages will have both message and
%% position pushed to disk as soon as they arrive; transient messages
%% can be written to disk (and thus both types can be evicted from
%% memory) under memory pressure. The question of whether a message is
%% in RAM and whether it is persistent are orthogonal.
%%
%% Messages are persisted using the queue index and the message
%% store. Normally the queue index holds the position of the message
%% *within this queue* along with a couple of small bits of metadata,
%% while the message store holds the message itself (including headers
%% and other properties).
%%
%% However, as an optimisation, small messages can be embedded
%% directly in the queue index and bypass the message store
%% altogether.
%%
%% Definitions:
%%
%% alpha: this is a message where both the message itself, and its
%%        position within the queue are held in RAM
%%
%% beta:  this is a message where the message itself is only held on
%%        disk (if persisted to the message store) but its position
%%        within the queue is held in RAM.
%%
%% gamma: this is a message where the message itself is only held on
%%        disk, but its position is both in RAM and on disk.
%%
%% delta: this is a collection of messages, represented by a single
%%        term, where the messages and their position are only held on
%%        disk.
%%
%% Note that for persistent messages, the message and its position
%% within the queue are always held on disk, *in addition* to being in
%% one of the above classifications.
%%
%% Also note that within this code, the term gamma seldom
%% appears. It's frequently the case that gammas are defined by betas
%% who have had their queue position recorded on disk.
%%
%% In general, messages move q1 -> q2 -> delta -> q3 -> q4, though
%% many of these steps are frequently skipped. q1 and q4 only hold
%% alphas, q2 and q3 hold both betas and gammas. When a message
%% arrives, its classification is determined. It is then added to the
%% rightmost appropriate queue.
%%
%% If a new message is determined to be a beta or gamma, q1 is
%% empty. If a new message is determined to be a delta, q1 and q2 are
%% empty (and actually q4 too).
%%
%% When removing messages from a queue, if q4 is empty then q3 is read
%% directly. If q3 becomes empty then the next segment's worth of
%% messages from delta are read into q3, reducing the size of
%% delta. If the queue is non empty, either q4 or q3 contain
%% entries. It is never permitted for delta to hold all the messages
%% in the queue.
%%
%% The duration indicated to us by the memory_monitor is used to
%% calculate, given our current ingress and egress rates, how many
%% messages we should hold in RAM (i.e. as alphas). We track the
%% ingress and egress rates for both messages and pending acks and
%% rates for both are considered when calculating the number of
%% messages to hold in RAM. When we need to push alphas to betas or
%% betas to gammas, we favour writing out messages that are further
%% from the head of the queue. This minimises writes to disk, as the
%% messages closer to the tail of the queue stay in the queue for
%% longer, thus do not need to be replaced as quickly by sending other
%% messages to disk.
%%
%% Whilst messages are pushed to disk and forgotten from RAM as soon
%% as requested by a new setting of the queue RAM duration, the
%% inverse is not true: we only load messages back into RAM as
%% demanded as the queue is read from. Thus only publishes to the
%% queue will take up available spare capacity.
%%
%% When we report our duration to the memory monitor, we calculate
%% average ingress and egress rates over the last two samples, and
%% then calculate our duration based on the sum of the ingress and
%% egress rates. More than two samples could be used, but it's a
%% balance between responding quickly enough to changes in
%% producers/consumers versus ignoring temporary blips. The problem
%% with temporary blips is that with just a few queues, they can have
%% substantial impact on the calculation of the average duration and
%% hence cause unnecessary I/O. Another alternative is to increase the
%% amqqueue_process:RAM_DURATION_UPDATE_PERIOD to beyond 5
%% seconds. However, that then runs the risk of being too slow to
%% inform the memory monitor of changes. Thus a 5 second interval,
%% plus a rolling average over the last two samples seems to work
%% well in practice.
%%
%% The sum of the ingress and egress rates is used because the egress
%% rate alone is not sufficient. Adding in the ingress rate means that
%% queues which are being flooded by messages are given more memory,
%% resulting in them being able to process the messages faster (by
%% doing less I/O, or at least deferring it) and thus helping keep
%% their mailboxes empty and thus the queue as a whole is more
%% responsive. If such a queue also has fast but previously idle
%% consumers, the consumer can then start to be driven as fast as it
%% can go, whereas if only egress rate was being used, the incoming
%% messages may have to be written to disk and then read back in,
%% resulting in the hard disk being a bottleneck in driving the
%% consumers. Generally, we want to give Rabbit every chance of
%% getting rid of messages as fast as possible and remaining
%% responsive, and using only the egress rate impacts that goal.
%%
%% Once the queue has more alphas than the target_ram_count, the
%% surplus must be converted to betas, if not gammas, if not rolled
%% into delta. The conditions under which these transitions occur
%% reflect the conflicting goals of minimising RAM cost per msg, and
%% minimising CPU cost per msg. Once the msg has become a beta, its
%% payload is no longer in RAM, thus a read from the msg_store must
%% occur before the msg can be delivered, but the RAM cost of a beta
%% is the same as a gamma, so converting a beta to gamma will not free
%% up any further RAM. To reduce the RAM cost further, the gamma must
%% be rolled into delta. Whilst recovering a beta or a gamma to an
%% alpha requires only one disk read (from the msg_store), recovering
%% a msg from within delta will require two reads (queue_index and
%% then msg_store). But delta has a near-0 per-msg RAM cost. So the
%% conflict is between using delta more, which will free up more
%% memory, but require additional CPU and disk ops, versus using delta
%% less and gammas and betas more, which will cost more memory, but
%% require fewer disk ops and less CPU overhead.
%%
%% In the case of a persistent msg published to a durable queue, the
%% msg is immediately written to the msg_store and queue_index. If
%% then additionally converted from an alpha, it'll immediately go to
%% a gamma (as it's already in queue_index), and cannot exist as a
%% beta. Thus a durable queue with a mixture of persistent and
%% transient msgs in it which has more messages than permitted by the
%% target_ram_count may contain an interspersed mixture of betas and
%% gammas in q2 and q3.
%%
%% There is then a ratio that controls how many betas and gammas there
%% can be. This is based on the target_ram_count and thus expresses
%% the fact that as the number of permitted alphas in the queue falls,
%% so should the number of betas and gammas fall (i.e. delta
%% grows). If q2 and q3 contain more than the permitted number of
%% betas and gammas, then the surplus are forcibly converted to gammas
%% (as necessary) and then rolled into delta. The ratio is that
%% delta/(betas+gammas+delta) equals
%% (betas+gammas+delta)/(target_ram_count+betas+gammas+delta). I.e. as
%% the target_ram_count shrinks to 0, so must betas and gammas.
%%
%% The conversion of betas to gammas is done in batches of at least
%% ?IO_BATCH_SIZE. This value should not be too small, otherwise the
%% frequent operations on the queues of q2 and q3 will not be
%% effectively amortised (switching the direction of queue access
%% defeats amortisation). Note that there is a natural upper bound due
%% to credit_flow limits on the alpha to beta conversion.
%%
%% The conversion from alphas to betas is chunked due to the
%% credit_flow limits of the msg_store. This further smooths the
%% effects of changes to the target_ram_count and ensures the queue
%% remains responsive even when there is a large amount of IO work to
%% do. The 'resume' callback is utilised to ensure that conversions
%% are done as promptly as possible whilst ensuring the queue remains
%% responsive.
%%
%% In the queue we keep track of both messages that are pending
%% delivery and messages that are pending acks. In the event of a
%% queue purge, we only need to load qi segments if the queue has
%% elements in deltas (i.e. it came under significant memory
%% pressure). In the event of a queue deletion, in addition to the
%% preceding, by keeping track of pending acks in RAM, we do not need
%% to search through qi segments looking for messages that are yet to
%% be acknowledged.
%%
%% Pending acks are recorded in memory by storing the message itself.
%% If the message has been sent to disk, we do not store the message
%% content. During memory reduction, pending acks containing message
%% content have that content removed and the corresponding messages
%% are pushed out to disk.
%%
%% Messages from pending acks are returned to q4, q3 and delta during
%% requeue, based on the limits of seq_id contained in each. Requeued
%% messages retain their original seq_id, maintaining order
%% when requeued.
%%
%% The order in which alphas are pushed to betas and pending acks
%% are pushed to disk is determined dynamically. We always prefer to
%% push messages for the source (alphas or acks) that is growing the
%% fastest (with growth measured as avg. ingress - avg. egress).
%%
%% Notes on Clean Shutdown
%% (This documents behaviour in variable_queue, queue_index and
%% msg_store.)
%%
%% In order to try to achieve as fast a start-up as possible, if a
%% clean shutdown occurs, we try to save out state to disk to reduce
%% work on startup. In the msg_store this takes the form of the
%% index_module's state, plus the file_summary ets table, and client
%% refs. In the VQ, this takes the form of the count of persistent
%% messages in the queue and references into the msg_stores. The
%% queue_index adds to these terms the details of its segments and
%% stores the terms in the queue directory.
%%
%% Two message stores are used. One is created for persistent messages
%% to durable queues that must survive restarts, and the other is used
%% for all other messages that just happen to need to be written to
%% disk. On start up we can therefore nuke the transient message
%% store, and be sure that the messages in the persistent store are
%% all that we need.
%%
%% The references to the msg_stores are there so that the msg_store
%% knows to only trust its saved state if all of the queues it was
%% previously talking to come up cleanly. Likewise, the queues
%% themselves (esp queue_index) skips work in init if all the queues
%% and msg_store were shutdown cleanly. This gives both good speed
%% improvements and also robustness so that if anything possibly went
%% wrong in shutdown (or there was subsequent manual tampering), all
%% messages and queues that can be recovered are recovered, safely.
%%
%% To delete transient messages lazily, the variable_queue, on
%% startup, stores the next_seq_id reported by the queue_index as the
%% transient_threshold. From that point on, whenever it's reading a
%% message off disk via the queue_index, if the seq_id is below this
%% threshold and the message is transient then it drops the message
%% (the message itself won't exist on disk because it would have been
%% stored in the transient msg_store which would have had its saved
%% state nuked on startup). This avoids the expensive operation of
%% scanning the entire queue on startup in order to delete transient
%% messages that were only pushed to disk to save memory.
%%
%%----------------------------------------------------------------------------

-behaviour(rabbit_backing_queue).

-record(vqstate,
        { q1,
          q2,
          delta,
          q3,
          q4,
          next_seq_id,
          ram_pending_ack,    %% msgs using store, still in RAM
          disk_pending_ack,   %% msgs in store, paged out
          qi_pending_ack,     %% msgs using qi, *can't* be paged out
          index_state,
          msg_store_clients,
          durable,
          transient_threshold,
          qi_embed_msgs_below,

          len,                %% w/o unacked
          bytes,              %% w/o unacked
          unacked_bytes,
          persistent_count,   %% w   unacked
          persistent_bytes,   %% w   unacked
          delta_transient_bytes,        %%

          target_ram_count,
          ram_msg_count,      %% w/o unacked
          ram_msg_count_prev,
          ram_ack_count_prev,
          ram_bytes,          %% w   unacked
          out_counter,
          in_counter,
          rates,
          msgs_on_disk,
          msg_indices_on_disk,
          unconfirmed,
          confirmed,
          ack_out_counter,
          ack_in_counter,
          %% Unlike the other counters these two do not feed into
          %% #rates{} and get reset
          disk_read_count,
          disk_write_count,

          io_batch_size,

          %% default queue or lazy queue
          mode,
          %% number of reduce_memory_usage executions, once it
          %% reaches a threshold the queue will manually trigger a runtime GC
	        %% see: maybe_execute_gc/1
          memory_reduction_run_count
        }).

-record(rates, { in, out, ack_in, ack_out, timestamp }).

-record(msg_status,
        { seq_id,
          msg_id,
          msg,
          is_persistent,
          is_delivered,
          msg_in_store,
          index_on_disk,
          persist_to,
          msg_props
        }).

-record(delta,
        { start_seq_id, %% start_seq_id is inclusive
          count,
          transient,
          end_seq_id    %% end_seq_id is exclusive
        }).

-define(HEADER_GUESS_SIZE, 100). %% see determine_persist_to/2
-define(PERSISTENT_MSG_STORE, msg_store_persistent).
-define(TRANSIENT_MSG_STORE,  msg_store_transient).
-define(QUEUE, lqueue).

-include("rabbit.hrl").
-include("rabbit_framing.hrl").

%%----------------------------------------------------------------------------

-rabbit_upgrade({multiple_routing_keys, local, []}).

-type seq_id()  :: non_neg_integer().

-type rates() :: #rates { in        :: float(),
                          out       :: float(),
                          ack_in    :: float(),
                          ack_out   :: float(),
                          timestamp :: rabbit_types:timestamp()}.

-type delta() :: #delta { start_seq_id :: non_neg_integer(),
                          count        :: non_neg_integer(),
                          end_seq_id   :: non_neg_integer() }.

%% The compiler (rightfully) complains that ack() and state() are
%% unused. For this reason we duplicate a -spec from
%% rabbit_backing_queue with the only intent being to remove
%% warnings. The problem here is that we can't parameterise the BQ
%% behaviour by these two types as we would like to. We still leave
%% these here for documentation purposes.
-type ack() :: seq_id().
-type state() :: #vqstate {
             q1                    :: ?QUEUE:?QUEUE(),
             q2                    :: ?QUEUE:?QUEUE(),
             delta                 :: delta(),
             q3                    :: ?QUEUE:?QUEUE(),
             q4                    :: ?QUEUE:?QUEUE(),
             next_seq_id           :: seq_id(),
             ram_pending_ack       :: gb_trees:tree(),
             disk_pending_ack      :: gb_trees:tree(),
             qi_pending_ack        :: gb_trees:tree(),
             index_state           :: any(),
             msg_store_clients     :: 'undefined' | {{any(), binary()},
                                                    {any(), binary()}},
             durable               :: boolean(),
             transient_threshold   :: non_neg_integer(),
             qi_embed_msgs_below   :: non_neg_integer(),

             len                   :: non_neg_integer(),
             bytes                 :: non_neg_integer(),
             unacked_bytes         :: non_neg_integer(),

             persistent_count      :: non_neg_integer(),
             persistent_bytes      :: non_neg_integer(),

             target_ram_count      :: non_neg_integer() | 'infinity',
             ram_msg_count         :: non_neg_integer(),
             ram_msg_count_prev    :: non_neg_integer(),
             ram_ack_count_prev    :: non_neg_integer(),
             ram_bytes             :: non_neg_integer(),
             out_counter           :: non_neg_integer(),
             in_counter            :: non_neg_integer(),
             rates                 :: rates(),
             msgs_on_disk          :: ?GB_SET_TYPE(),
             msg_indices_on_disk   :: ?GB_SET_TYPE(),
             unconfirmed           :: ?GB_SET_TYPE(),
             confirmed             :: ?GB_SET_TYPE(),
             ack_out_counter       :: non_neg_integer(),
             ack_in_counter        :: non_neg_integer(),
             disk_read_count       :: non_neg_integer(),
             disk_write_count      :: non_neg_integer(),

             io_batch_size         :: pos_integer(),
             mode                  :: 'default' | 'lazy',
             memory_reduction_run_count :: non_neg_integer()}.
%% Duplicated from rabbit_backing_queue
-spec ack([ack()], state()) -> {[rabbit_guid:guid()], state()}.

-spec multiple_routing_keys() -> 'ok'.

-define(BLANK_DELTA, #delta { start_seq_id = undefined,
                              count        = 0,
                              transient    = 0,
                              end_seq_id   = undefined }).
-define(BLANK_DELTA_PATTERN(Z), #delta { start_seq_id = Z,
                                         count        = 0,
                                         transient    = 0,
                                         end_seq_id   = Z }).

-define(MICROS_PER_SECOND, 1000000.0).

%% We're sampling every 5s for RAM duration; a half life that is of
%% the same order of magnitude is probably about right.
-define(RATE_AVG_HALF_LIFE, 5.0).

%% We will recalculate the #rates{} every time we get asked for our
%% RAM duration, or every N messages published, whichever is
%% sooner. We do this since the priority calculations in
%% rabbit_amqqueue_process need fairly fresh rates.
-define(MSGS_PER_RATE_CALC, 100).


%% we define the garbage collector threshold
%% it needs to tune the GC calls inside `reduce_memory_use`
%% see: rabbitmq-server-973 and `maybe_execute_gc` function
-define(DEFAULT_EXPLICIT_GC_RUN_OP_THRESHOLD, 250).
-define(EXPLICIT_GC_RUN_OP_THRESHOLD,
    case get(explicit_gc_run_operation_threshold) of
        undefined ->
            Val = rabbit_misc:get_env(rabbit, lazy_queue_explicit_gc_run_operation_threshold,
                ?DEFAULT_EXPLICIT_GC_RUN_OP_THRESHOLD),
            put(explicit_gc_run_operation_threshold, Val),
            Val;
        Val       -> Val
    end).

%%----------------------------------------------------------------------------
%% Public API
%%----------------------------------------------------------------------------

start(DurableQueues) ->
    {AllTerms, StartFunState} = rabbit_queue_index:start(DurableQueues),
    start_msg_store(
      [Ref || Terms <- AllTerms,
              Terms /= non_clean_shutdown,
              begin
                  Ref = proplists:get_value(persistent_ref, Terms),
                  Ref =/= undefined
              end],
      StartFunState),
    {ok, AllTerms}.

stop() ->
    ok = stop_msg_store(),
    ok = rabbit_queue_index:stop().

start_msg_store(Refs, StartFunState) ->
    ok = rabbit_sup:start_child(?TRANSIENT_MSG_STORE, rabbit_msg_store,
                                [?TRANSIENT_MSG_STORE, rabbit_mnesia:dir(),
                                 undefined,  {fun (ok) -> finished end, ok}]),
    ok = rabbit_sup:start_child(?PERSISTENT_MSG_STORE, rabbit_msg_store,
                                [?PERSISTENT_MSG_STORE, rabbit_mnesia:dir(),
                                 Refs, StartFunState]).

stop_msg_store() ->
    ok = rabbit_sup:stop_child(?PERSISTENT_MSG_STORE),
    ok = rabbit_sup:stop_child(?TRANSIENT_MSG_STORE).

init(Queue, Recover, Callback) ->
    init(
      Queue, Recover, Callback,
      fun (MsgIds, ActionTaken) ->
              msgs_written_to_disk(Callback, MsgIds, ActionTaken)
      end,
      fun (MsgIds) -> msg_indices_written_to_disk(Callback, MsgIds) end,
      fun (MsgIds) -> msgs_and_indices_written_to_disk(Callback, MsgIds) end).

init(#amqqueue { name = QueueName, durable = IsDurable }, new,
     AsyncCallback, MsgOnDiskFun, MsgIdxOnDiskFun, MsgAndIdxOnDiskFun) ->
    IndexState = rabbit_queue_index:init(QueueName,
                                         MsgIdxOnDiskFun, MsgAndIdxOnDiskFun),
    init(IsDurable, IndexState, 0, 0, [],
         case IsDurable of
             true  -> msg_store_client_init(?PERSISTENT_MSG_STORE,
                                            MsgOnDiskFun, AsyncCallback);
             false -> undefined
         end,
         msg_store_client_init(?TRANSIENT_MSG_STORE, undefined, AsyncCallback));

%% We can be recovering a transient queue if it crashed
init(#amqqueue { name = QueueName, durable = IsDurable }, Terms,
     AsyncCallback, MsgOnDiskFun, MsgIdxOnDiskFun, MsgAndIdxOnDiskFun) ->
    {PRef, RecoveryTerms} = process_recovery_terms(Terms),
    {PersistentClient, ContainsCheckFun} =
        case IsDurable of
            true  -> C = msg_store_client_init(?PERSISTENT_MSG_STORE, PRef,
                                               MsgOnDiskFun, AsyncCallback),
                     {C, fun (MsgId) when is_binary(MsgId) ->
                                 rabbit_msg_store:contains(MsgId, C);
                             (#basic_message{is_persistent = Persistent}) ->
                                 Persistent
                         end};
            false -> {undefined, fun(_MsgId) -> false end}
        end,
    TransientClient  = msg_store_client_init(?TRANSIENT_MSG_STORE,
                                             undefined, AsyncCallback),
    {DeltaCount, DeltaBytes, IndexState} =
        rabbit_queue_index:recover(
          QueueName, RecoveryTerms,
          rabbit_msg_store:successfully_recovered_state(?PERSISTENT_MSG_STORE),
          ContainsCheckFun, MsgIdxOnDiskFun, MsgAndIdxOnDiskFun),
    init(IsDurable, IndexState, DeltaCount, DeltaBytes, RecoveryTerms,
         PersistentClient, TransientClient).

process_recovery_terms(Terms=non_clean_shutdown) ->
    {rabbit_guid:gen(), Terms};
process_recovery_terms(Terms) ->
    case proplists:get_value(persistent_ref, Terms) of
        undefined -> {rabbit_guid:gen(), []};
        PRef      -> {PRef, Terms}
    end.

terminate(_Reason, State) ->
    State1 = #vqstate { persistent_count  = PCount,
                        persistent_bytes  = PBytes,
                        index_state       = IndexState,
                        msg_store_clients = {MSCStateP, MSCStateT} } =
        purge_pending_ack(true, State),
    PRef = case MSCStateP of
               undefined -> undefined;
               _         -> ok = rabbit_msg_store:client_terminate(MSCStateP),
                            rabbit_msg_store:client_ref(MSCStateP)
           end,
    ok = rabbit_msg_store:client_delete_and_terminate(MSCStateT),
    Terms = [{persistent_ref,   PRef},
             {persistent_count, PCount},
             {persistent_bytes, PBytes}],
    a(State1 #vqstate { index_state       = rabbit_queue_index:terminate(
                                              Terms, IndexState),
                        msg_store_clients = undefined }).

%% the only difference between purge and delete is that delete also
%% needs to delete everything that's been delivered and not ack'd.
delete_and_terminate(_Reason, State) ->
    %% Normally when we purge messages we interact with the qi by
    %% issues delivers and acks for every purged message. In this case
    %% we don't need to do that, so we just delete the qi.
    State1 = purge_and_index_reset(State),
    State2 = #vqstate { msg_store_clients = {MSCStateP, MSCStateT} } =
        purge_pending_ack_delete_and_terminate(State1),
    case MSCStateP of
        undefined -> ok;
        _         -> rabbit_msg_store:client_delete_and_terminate(MSCStateP)
    end,
    rabbit_msg_store:client_delete_and_terminate(MSCStateT),
    a(State2 #vqstate { msg_store_clients = undefined }).

delete_crashed(#amqqueue{name = QName}) ->
    ok = rabbit_queue_index:erase(QName).

purge(State = #vqstate { len = Len }) ->
    case is_pending_ack_empty(State) and is_unconfirmed_empty(State) of
        true ->
            {Len, purge_and_index_reset(State)};
        false ->
            {Len, purge_when_pending_acks(State)}
    end.

purge_acks(State) -> a(purge_pending_ack(false, State)).

publish(Msg, MsgProps, IsDelivered, ChPid, Flow, State) ->
    State1 =
        publish1(Msg, MsgProps, IsDelivered, ChPid, Flow,
                 fun maybe_write_to_disk/4,
                 State),
    a(reduce_memory_use(maybe_update_rates(State1))).

batch_publish(Publishes, ChPid, Flow, State) ->
    {ChPid, Flow, State1} =
        lists:foldl(fun batch_publish1/2, {ChPid, Flow, State}, Publishes),
    State2 = ui(State1),
    a(reduce_memory_use(maybe_update_rates(State2))).

publish_delivered(Msg, MsgProps, ChPid, Flow, State) ->
    {SeqId, State1} =
        publish_delivered1(Msg, MsgProps, ChPid, Flow,
                           fun maybe_write_to_disk/4,
                           State),
    {SeqId, a(reduce_memory_use(maybe_update_rates(State1)))}.

batch_publish_delivered(Publishes, ChPid, Flow, State) ->
    {ChPid, Flow, SeqIds, State1} =
        lists:foldl(fun batch_publish_delivered1/2,
                    {ChPid, Flow, [], State}, Publishes),
    State2 = ui(State1),
    {lists:reverse(SeqIds), a(reduce_memory_use(maybe_update_rates(State2)))}.

discard(_MsgId, _ChPid, _Flow, State) -> State.

drain_confirmed(State = #vqstate { confirmed = C }) ->
    case gb_sets:is_empty(C) of
        true  -> {[], State}; %% common case
        false -> {gb_sets:to_list(C), State #vqstate {
                                        confirmed = gb_sets:new() }}
    end.

dropwhile(Pred, State) ->
    {MsgProps, State1} =
        remove_by_predicate(Pred, State),
    {MsgProps, a(State1)}.

fetchwhile(Pred, Fun, Acc, State) ->
    {MsgProps, Acc1, State1} =
         fetch_by_predicate(Pred, Fun, Acc, State),
    {MsgProps, Acc1, a(State1)}.

fetch(AckRequired, State) ->
    case queue_out(State) of
        {empty, State1} ->
            {empty, a(State1)};
        {{value, MsgStatus}, State1} ->
            %% it is possible that the message wasn't read from disk
            %% at this point, so read it in.
            {Msg, State2} = read_msg(MsgStatus, State1),
            {AckTag, State3} = remove(AckRequired, MsgStatus, State2),
            {{Msg, MsgStatus#msg_status.is_delivered, AckTag}, a(State3)}
    end.

drop(AckRequired, State) ->
    case queue_out(State) of
        {empty, State1} ->
            {empty, a(State1)};
        {{value, MsgStatus}, State1} ->
            {AckTag, State2} = remove(AckRequired, MsgStatus, State1),
            {{MsgStatus#msg_status.msg_id, AckTag}, a(State2)}
    end.

ack([], State) ->
    {[], State};
%% optimisation: this head is essentially a partial evaluation of the
%% general case below, for the single-ack case.
ack([SeqId], State) ->
    case remove_pending_ack(true, SeqId, State) of
        {none, _} ->
            State;
        {#msg_status { msg_id        = MsgId,
                       is_persistent = IsPersistent,
                       msg_in_store  = MsgInStore,
                       index_on_disk = IndexOnDisk },
         State1 = #vqstate { index_state       = IndexState,
                             msg_store_clients = MSCState,
                             ack_out_counter   = AckOutCount }} ->
            IndexState1 = case IndexOnDisk of
                              true  -> rabbit_queue_index:ack([SeqId], IndexState);
                              false -> IndexState
                          end,
            case MsgInStore of
                true  -> ok = msg_store_remove(MSCState, IsPersistent, [MsgId]);
                false -> ok
            end,
            {[MsgId],
             a(State1 #vqstate { index_state      = IndexState1,
                                 ack_out_counter  = AckOutCount + 1 })}
    end;
ack(AckTags, State) ->
    {{IndexOnDiskSeqIds, MsgIdsByStore, AllMsgIds},
     State1 = #vqstate { index_state       = IndexState,
                         msg_store_clients = MSCState,
                         ack_out_counter   = AckOutCount }} =
        lists:foldl(
          fun (SeqId, {Acc, State2}) ->
                  case remove_pending_ack(true, SeqId, State2) of
                      {none, _} ->
                          {Acc, State2};
                      {MsgStatus, State3} ->
                          {accumulate_ack(MsgStatus, Acc), State3}
                  end
          end, {accumulate_ack_init(), State}, AckTags),
    IndexState1 = rabbit_queue_index:ack(IndexOnDiskSeqIds, IndexState),
    remove_msgs_by_id(MsgIdsByStore, MSCState),
    {lists:reverse(AllMsgIds),
     a(State1 #vqstate { index_state      = IndexState1,
                         ack_out_counter  = AckOutCount + length(AckTags) })}.

requeue(AckTags, #vqstate { mode       = default,
                            delta      = Delta,
                            q3         = Q3,
                            q4         = Q4,
                            in_counter = InCounter,
                            len        = Len } = State) ->
    {SeqIds,  Q4a, MsgIds,  State1} = queue_merge(lists:sort(AckTags), Q4, [],
                                                  beta_limit(Q3),
                                                  fun publish_alpha/2, State),
    {SeqIds1, Q3a, MsgIds1, State2} = queue_merge(SeqIds, Q3, MsgIds,
                                                  delta_limit(Delta),
                                                  fun publish_beta/2, State1),
    {Delta1, MsgIds2, State3}       = delta_merge(SeqIds1, Delta, MsgIds1,
                                                  State2),
    MsgCount = length(MsgIds2),
    {MsgIds2, a(reduce_memory_use(
                  maybe_update_rates(ui(
                    State3 #vqstate { delta      = Delta1,
                                      q3         = Q3a,
                                      q4         = Q4a,
                                      in_counter = InCounter + MsgCount,
                                      len        = Len + MsgCount }))))};
requeue(AckTags, #vqstate { mode       = lazy,
                            delta      = Delta,
                            q3         = Q3,
                            in_counter = InCounter,
                            len        = Len } = State) ->
    {SeqIds, Q3a, MsgIds, State1} = queue_merge(lists:sort(AckTags), Q3, [],
                                                delta_limit(Delta),
                                                fun publish_beta/2, State),
    {Delta1, MsgIds1, State2}     = delta_merge(SeqIds, Delta, MsgIds,
                                                State1),
    MsgCount = length(MsgIds1),
    {MsgIds1, a(reduce_memory_use(
                  maybe_update_rates(ui(
                    State2 #vqstate { delta      = Delta1,
                                      q3         = Q3a,
                                      in_counter = InCounter + MsgCount,
                                      len        = Len + MsgCount }))))}.

ackfold(MsgFun, Acc, State, AckTags) ->
    {AccN, StateN} =
        lists:foldl(fun(SeqId, {Acc0, State0}) ->
                            MsgStatus = lookup_pending_ack(SeqId, State0),
                            {Msg, State1} = read_msg(MsgStatus, State0),
                            {MsgFun(Msg, SeqId, Acc0), State1}
                    end, {Acc, State}, AckTags),
    {AccN, a(StateN)}.

fold(Fun, Acc, State = #vqstate{index_state = IndexState}) ->
    {Its, IndexState1} = lists:foldl(fun inext/2, {[], IndexState},
                                     [msg_iterator(State),
                                      disk_ack_iterator(State),
                                      ram_ack_iterator(State),
                                      qi_ack_iterator(State)]),
    ifold(Fun, Acc, Its, State#vqstate{index_state = IndexState1}).

len(#vqstate { len = Len }) -> Len.

is_empty(State) -> 0 == len(State).

depth(State) ->
    len(State) + count_pending_acks(State).

set_ram_duration_target(
  DurationTarget, State = #vqstate {
                    rates = #rates { in      = AvgIngressRate,
                                     out     = AvgEgressRate,
                                     ack_in  = AvgAckIngressRate,
                                     ack_out = AvgAckEgressRate },
                    target_ram_count = TargetRamCount }) ->
    Rate =
        AvgEgressRate + AvgIngressRate + AvgAckEgressRate + AvgAckIngressRate,
    TargetRamCount1 =
        case DurationTarget of
            infinity  -> infinity;
            _         -> trunc(DurationTarget * Rate) %% msgs = sec * msgs/sec
        end,
    State1 = State #vqstate { target_ram_count = TargetRamCount1 },
    a(case TargetRamCount1 == infinity orelse
          (TargetRamCount =/= infinity andalso
           TargetRamCount1 >= TargetRamCount) of
          true  -> State1;
          false -> reduce_memory_use(State1)
      end).

maybe_update_rates(State = #vqstate{ in_counter  = InCount,
                                     out_counter = OutCount })
  when InCount + OutCount > ?MSGS_PER_RATE_CALC ->
    update_rates(State);
maybe_update_rates(State) ->
    State.

update_rates(State = #vqstate{ in_counter      =     InCount,
                               out_counter     =    OutCount,
                               ack_in_counter  =  AckInCount,
                               ack_out_counter = AckOutCount,
                               rates = #rates{ in        =     InRate,
                                               out       =    OutRate,
                                               ack_in    =  AckInRate,
                                               ack_out   = AckOutRate,
                                               timestamp = TS }}) ->
    Now = time_compat:monotonic_time(),

    Rates = #rates { in        = update_rate(Now, TS,     InCount,     InRate),
                     out       = update_rate(Now, TS,    OutCount,    OutRate),
                     ack_in    = update_rate(Now, TS,  AckInCount,  AckInRate),
                     ack_out   = update_rate(Now, TS, AckOutCount, AckOutRate),
                     timestamp = Now },

    State#vqstate{ in_counter      = 0,
                   out_counter     = 0,
                   ack_in_counter  = 0,
                   ack_out_counter = 0,
                   rates           = Rates }.

update_rate(Now, TS, Count, Rate) ->
    Time = time_compat:convert_time_unit(Now - TS, native, micro_seconds) /
        ?MICROS_PER_SECOND,
    if
        Time == 0 -> Rate;
        true      -> rabbit_misc:moving_average(Time, ?RATE_AVG_HALF_LIFE,
                                                Count / Time, Rate)
    end.

ram_duration(State) ->
    State1 = #vqstate { rates = #rates { in      = AvgIngressRate,
                                         out     = AvgEgressRate,
                                         ack_in  = AvgAckIngressRate,
                                         ack_out = AvgAckEgressRate },
                        ram_msg_count      = RamMsgCount,
                        ram_msg_count_prev = RamMsgCountPrev,
                        ram_pending_ack    = RPA,
                        qi_pending_ack     = QPA,
                        ram_ack_count_prev = RamAckCountPrev } =
        update_rates(State),

    RamAckCount = gb_trees:size(RPA) + gb_trees:size(QPA),

    Duration = %% msgs+acks / (msgs+acks/sec) == sec
        case lists:all(fun (X) -> X < 0.01 end,
                       [AvgEgressRate, AvgIngressRate,
                        AvgAckEgressRate, AvgAckIngressRate]) of
            true  -> infinity;
            false -> (RamMsgCountPrev + RamMsgCount +
                          RamAckCount + RamAckCountPrev) /
                         (4 * (AvgEgressRate + AvgIngressRate +
                                   AvgAckEgressRate + AvgAckIngressRate))
        end,

    {Duration, State1}.

needs_timeout(#vqstate { index_state = IndexState }) ->
    case rabbit_queue_index:needs_sync(IndexState) of
        confirms -> timed;
        other    -> idle;
        false    -> false
    end.

timeout(State = #vqstate { index_state = IndexState }) ->
    State #vqstate { index_state = rabbit_queue_index:sync(IndexState) }.

handle_pre_hibernate(State = #vqstate { index_state = IndexState }) ->
    State #vqstate { index_state = rabbit_queue_index:flush(IndexState) }.

resume(State) -> a(reduce_memory_use(State)).

msg_rates(#vqstate { rates = #rates { in  = AvgIngressRate,
                                      out = AvgEgressRate } }) ->
    {AvgIngressRate, AvgEgressRate}.

info(messages_ready_ram, #vqstate{ram_msg_count = RamMsgCount}) ->
    RamMsgCount;
info(messages_unacknowledged_ram, #vqstate{ram_pending_ack = RPA,
                                           qi_pending_ack  = QPA}) ->
    gb_trees:size(RPA) + gb_trees:size(QPA);
info(messages_ram, State) ->
    info(messages_ready_ram, State) + info(messages_unacknowledged_ram, State);
info(messages_persistent, #vqstate{persistent_count = PersistentCount}) ->
    PersistentCount;
info(messages_paged_out, #vqstate{delta = #delta{transient = Count}}) ->
    Count;
info(message_bytes, #vqstate{bytes         = Bytes,
                             unacked_bytes = UBytes}) ->
    Bytes + UBytes;
info(message_bytes_ready, #vqstate{bytes = Bytes}) ->
    Bytes;
info(message_bytes_unacknowledged, #vqstate{unacked_bytes = UBytes}) ->
    UBytes;
info(message_bytes_ram, #vqstate{ram_bytes = RamBytes}) ->
    RamBytes;
info(message_bytes_persistent, #vqstate{persistent_bytes = PersistentBytes}) ->
    PersistentBytes;
info(message_bytes_paged_out, #vqstate{delta_transient_bytes = PagedOutBytes}) ->
    PagedOutBytes;
info(head_message_timestamp, #vqstate{
          q3               = Q3,
          q4               = Q4,
          ram_pending_ack  = RPA,
          qi_pending_ack   = QPA}) ->
          head_message_timestamp(Q3, Q4, RPA, QPA);
info(disk_reads, #vqstate{disk_read_count = Count}) ->
    Count;
info(disk_writes, #vqstate{disk_write_count = Count}) ->
    Count;
info(backing_queue_status, #vqstate {
          q1 = Q1, q2 = Q2, delta = Delta, q3 = Q3, q4 = Q4,
          mode             = Mode,
          len              = Len,
          target_ram_count = TargetRamCount,
          next_seq_id      = NextSeqId,
          rates            = #rates { in      = AvgIngressRate,
                                      out     = AvgEgressRate,
                                      ack_in  = AvgAckIngressRate,
                                      ack_out = AvgAckEgressRate }}) ->

    [ {mode                , Mode},
      {q1                  , ?QUEUE:len(Q1)},
      {q2                  , ?QUEUE:len(Q2)},
      {delta               , Delta},
      {q3                  , ?QUEUE:len(Q3)},
      {q4                  , ?QUEUE:len(Q4)},
      {len                 , Len},
      {target_ram_count    , TargetRamCount},
      {next_seq_id         , NextSeqId},
      {avg_ingress_rate    , AvgIngressRate},
      {avg_egress_rate     , AvgEgressRate},
      {avg_ack_ingress_rate, AvgAckIngressRate},
      {avg_ack_egress_rate , AvgAckEgressRate} ];
info(Item, _) ->
    throw({bad_argument, Item}).

invoke(?MODULE, Fun, State) -> Fun(?MODULE, State);
invoke(      _,   _, State) -> State.

is_duplicate(_Msg, State) -> {false, State}.

set_queue_mode(Mode, State = #vqstate { mode = Mode }) ->
    State;
set_queue_mode(lazy, State = #vqstate {
                                target_ram_count = TargetRamCount }) ->
    %% To become a lazy queue we need to page everything to disk first.
    State1 = convert_to_lazy(State),
    %% restore the original target_ram_count
    a(State1 #vqstate { mode = lazy, target_ram_count = TargetRamCount });
set_queue_mode(default, State) ->
    %% becoming a default queue means loading messages from disk like
    %% when a queue is recovered.
    a(maybe_deltas_to_betas(State #vqstate { mode = default }));
set_queue_mode(_, State) ->
    State.

zip_msgs_and_acks(Msgs, AckTags, Accumulator, _State) ->
    lists:foldl(fun ({{#basic_message{ id = Id }, _Props}, AckTag}, Acc) ->
                        [{Id, AckTag} | Acc]
                end, Accumulator, lists:zip(Msgs, AckTags)).

convert_to_lazy(State) ->
    State1 = #vqstate { delta = Delta, q3 = Q3, len = Len } =
        set_ram_duration_target(0, State),
    case Delta#delta.count + ?QUEUE:len(Q3) == Len of
        true ->
            State1;
        false ->
            %% When pushing messages to disk, we might have been
            %% blocked by the msg_store, so we need to see if we have
            %% to wait for more credit, and then keep paging messages.
            %%
            %% The amqqueue_process could have taken care of this, but
            %% between the time it receives the bump_credit msg and
            %% calls BQ:resume to keep paging messages to disk, some
            %% other request may arrive to the BQ which at this moment
            %% is not in a proper state for a lazy BQ (unless all
            %% messages have been paged to disk already).
            wait_for_msg_store_credit(),
            convert_to_lazy(resume(State1))
    end.

wait_for_msg_store_credit() ->
    case credit_flow:blocked() of
        true  -> receive
                     {bump_credit, Msg} ->
                         credit_flow:handle_bump_msg(Msg)
                 end;
        false -> ok
    end.

%% Get the Timestamp property of the first msg, if present. This is
%% the one with the oldest timestamp among the heads of the pending
%% acks and unread queues.  We can't check disk_pending_acks as these
%% are paged out - we assume some will soon be paged in rather than
%% forcing it to happen.  Pending ack msgs are included as they are
%% regarded as unprocessed until acked, this also prevents the result
%% apparently oscillating during repeated rejects.  Q3 is only checked
%% when Q4 is empty as any Q4 msg will be earlier.
head_message_timestamp(Q3, Q4, RPA, QPA) ->
    HeadMsgs = [ HeadMsgStatus#msg_status.msg ||
                   HeadMsgStatus <-
                       [ get_qs_head([Q4, Q3]),
                         get_pa_head(RPA),
                         get_pa_head(QPA) ],
                   HeadMsgStatus /= undefined,
                   HeadMsgStatus#msg_status.msg /= undefined ],

    Timestamps =
        [Timestamp || HeadMsg <- HeadMsgs,
                      Timestamp <- [rabbit_basic:extract_timestamp(
                                      HeadMsg#basic_message.content)],
                      Timestamp /= undefined
        ],

    case Timestamps == [] of
        true -> '';
        false -> lists:min(Timestamps)
    end.

get_qs_head(Qs) ->
    catch lists:foldl(
            fun (Q, Acc) ->
                    case get_q_head(Q) of
                        undefined -> Acc;
                        Val -> throw(Val)
                    end
            end, undefined, Qs).

get_q_head(Q) ->
    get_collection_head(Q, fun ?QUEUE:is_empty/1, fun ?QUEUE:peek/1).

get_pa_head(PA) ->
    get_collection_head(PA, fun gb_trees:is_empty/1, fun gb_trees:smallest/1).

get_collection_head(Col, IsEmpty, GetVal) ->
    case IsEmpty(Col) of
        false ->
            {_, MsgStatus} = GetVal(Col),
            MsgStatus;
        true  -> undefined
    end.

%%----------------------------------------------------------------------------
%% Minor helpers
%%----------------------------------------------------------------------------
a(State = #vqstate { q1 = Q1, q2 = Q2, delta = Delta, q3 = Q3, q4 = Q4,
                     mode             = default,
                     len              = Len,
                     bytes            = Bytes,
                     unacked_bytes    = UnackedBytes,
                     persistent_count = PersistentCount,
                     persistent_bytes = PersistentBytes,
                     ram_msg_count    = RamMsgCount,
                     ram_bytes        = RamBytes}) ->
    E1 = ?QUEUE:is_empty(Q1),
    E2 = ?QUEUE:is_empty(Q2),
    ED = Delta#delta.count == 0,
    E3 = ?QUEUE:is_empty(Q3),
    E4 = ?QUEUE:is_empty(Q4),
    LZ = Len == 0,

    %% if q1 has messages then q3 cannot be empty. See publish/6.
    true = E1 or not E3,
    %% if q2 has messages then we have messages in delta (paged to
    %% disk). See push_alphas_to_betas/2.
    true = E2 or not ED,
    %% if delta has messages then q3 cannot be empty. This is enforced
    %% by paging, where min([?SEGMENT_ENTRY_COUNT, len(q3)]) messages
    %% are always kept on RAM.
    true = ED or not E3,
    %% if the queue length is 0, then q3 and q4 must be empty.
    true = LZ == (E3 and E4),

    true = Len             >= 0,
    true = Bytes           >= 0,
    true = UnackedBytes    >= 0,
    true = PersistentCount >= 0,
    true = PersistentBytes >= 0,
    true = RamMsgCount     >= 0,
    true = RamMsgCount     =< Len,
    true = RamBytes        >= 0,
    true = RamBytes        =< Bytes + UnackedBytes,

    State;
a(State = #vqstate { q1 = Q1, q2 = Q2, delta = Delta, q3 = Q3, q4 = Q4,
                     mode             = lazy,
                     len              = Len,
                     bytes            = Bytes,
                     unacked_bytes    = UnackedBytes,
                     persistent_count = PersistentCount,
                     persistent_bytes = PersistentBytes,
                     ram_msg_count    = RamMsgCount,
                     ram_bytes        = RamBytes}) ->
    E1 = ?QUEUE:is_empty(Q1),
    E2 = ?QUEUE:is_empty(Q2),
    ED = Delta#delta.count == 0,
    E3 = ?QUEUE:is_empty(Q3),
    E4 = ?QUEUE:is_empty(Q4),
    LZ = Len == 0,
    L3 = ?QUEUE:len(Q3),

    %% q1 must always be empty, since q1 only gets messages during
    %% publish, but for lazy queues messages go straight to delta.
    true = E1,

    %% q2 only gets messages from q1 when push_alphas_to_betas is
    %% called for a non empty delta, which won't be the case for a
    %% lazy queue. This means q2 must always be empty.
    true = E2,

    %% q4 must always be empty, since q1 only gets messages during
    %% publish, but for lazy queues messages go straight to delta.
    true = E4,

    %% if the queue is empty, then delta is empty and q3 is empty.
    true = LZ == (ED and E3),

    %% There should be no messages in q1, q2, and q4
    true = Delta#delta.count + L3 == Len,

    true = Len             >= 0,
    true = Bytes           >= 0,
    true = UnackedBytes    >= 0,
    true = PersistentCount >= 0,
    true = PersistentBytes >= 0,
    true = RamMsgCount     >= 0,
    true = RamMsgCount     =< Len,
    true = RamBytes        >= 0,
    true = RamBytes        =< Bytes + UnackedBytes,

    State.

d(Delta = #delta { start_seq_id = Start, count = Count, end_seq_id = End })
  when Start + Count =< End ->
    Delta.

m(MsgStatus = #msg_status { is_persistent = IsPersistent,
                            msg_in_store  = MsgInStore,
                            index_on_disk = IndexOnDisk }) ->
    true = (not IsPersistent) or IndexOnDisk,
    true = msg_in_ram(MsgStatus) or MsgInStore,
    MsgStatus.

one_if(true ) -> 1;
one_if(false) -> 0.

cons_if(true,   E, L) -> [E | L];
cons_if(false, _E, L) -> L.

gb_sets_maybe_insert(false, _Val, Set) -> Set;
gb_sets_maybe_insert(true,   Val, Set) -> gb_sets:add(Val, Set).

msg_status(IsPersistent, IsDelivered, SeqId,
           Msg = #basic_message {id = MsgId}, MsgProps, IndexMaxSize) ->
    #msg_status{seq_id        = SeqId,
                msg_id        = MsgId,
                msg           = Msg,
                is_persistent = IsPersistent,
                is_delivered  = IsDelivered,
                msg_in_store  = false,
                index_on_disk = false,
                persist_to    = determine_persist_to(Msg, MsgProps, IndexMaxSize),
                msg_props     = MsgProps}.

beta_msg_status({Msg = #basic_message{id = MsgId},
                 SeqId, MsgProps, IsPersistent, IsDelivered}) ->
    MS0 = beta_msg_status0(SeqId, MsgProps, IsPersistent, IsDelivered),
    MS0#msg_status{msg_id       = MsgId,
                   msg          = Msg,
                   persist_to   = queue_index,
                   msg_in_store = false};

beta_msg_status({MsgId, SeqId, MsgProps, IsPersistent, IsDelivered}) ->
    MS0 = beta_msg_status0(SeqId, MsgProps, IsPersistent, IsDelivered),
    MS0#msg_status{msg_id       = MsgId,
                   msg          = undefined,
                   persist_to   = msg_store,
                   msg_in_store = true}.

beta_msg_status0(SeqId, MsgProps, IsPersistent, IsDelivered) ->
  #msg_status{seq_id        = SeqId,
              msg           = undefined,
              is_persistent = IsPersistent,
              is_delivered  = IsDelivered,
              index_on_disk = true,
              msg_props     = MsgProps}.

trim_msg_status(MsgStatus) ->
    case persist_to(MsgStatus) of
        msg_store   -> MsgStatus#msg_status{msg = undefined};
        queue_index -> MsgStatus
    end.

with_msg_store_state({MSCStateP, MSCStateT},  true, Fun) ->
    {Result, MSCStateP1} = Fun(MSCStateP),
    {Result, {MSCStateP1, MSCStateT}};
with_msg_store_state({MSCStateP, MSCStateT}, false, Fun) ->
    {Result, MSCStateT1} = Fun(MSCStateT),
    {Result, {MSCStateP, MSCStateT1}}.

with_immutable_msg_store_state(MSCState, IsPersistent, Fun) ->
    {Res, MSCState} = with_msg_store_state(MSCState, IsPersistent,
                                           fun (MSCState1) ->
                                                   {Fun(MSCState1), MSCState1}
                                           end),
    Res.

msg_store_client_init(MsgStore, MsgOnDiskFun, Callback) ->
    msg_store_client_init(MsgStore, rabbit_guid:gen(), MsgOnDiskFun,
                          Callback).

msg_store_client_init(MsgStore, Ref, MsgOnDiskFun, Callback) ->
    CloseFDsFun = msg_store_close_fds_fun(MsgStore =:= ?PERSISTENT_MSG_STORE),
    rabbit_msg_store:client_init(MsgStore, Ref, MsgOnDiskFun,
                                 fun () -> Callback(?MODULE, CloseFDsFun) end).

msg_store_write(MSCState, IsPersistent, MsgId, Msg) ->
    with_immutable_msg_store_state(
      MSCState, IsPersistent,
      fun (MSCState1) ->
              rabbit_msg_store:write_flow(MsgId, Msg, MSCState1)
      end).

msg_store_read(MSCState, IsPersistent, MsgId) ->
    with_msg_store_state(
      MSCState, IsPersistent,
      fun (MSCState1) ->
              rabbit_msg_store:read(MsgId, MSCState1)
      end).

msg_store_remove(MSCState, IsPersistent, MsgIds) ->
    with_immutable_msg_store_state(
      MSCState, IsPersistent,
      fun (MCSState1) ->
              rabbit_msg_store:remove(MsgIds, MCSState1)
      end).

msg_store_close_fds(MSCState, IsPersistent) ->
    with_msg_store_state(
      MSCState, IsPersistent,
      fun (MSCState1) -> rabbit_msg_store:close_all_indicated(MSCState1) end).

msg_store_close_fds_fun(IsPersistent) ->
    fun (?MODULE, State = #vqstate { msg_store_clients = MSCState }) ->
            {ok, MSCState1} = msg_store_close_fds(MSCState, IsPersistent),
            State #vqstate { msg_store_clients = MSCState1 }
    end.

maybe_write_delivered(false, _SeqId, IndexState) ->
    IndexState;
maybe_write_delivered(true, SeqId, IndexState) ->
    rabbit_queue_index:deliver([SeqId], IndexState).

betas_from_index_entries(List, TransientThreshold, DelsAndAcksFun, State) ->
    {Filtered, Delivers, Acks, RamReadyCount, RamBytes, TransientCount, TransientBytes} =
        lists:foldr(
          fun ({_MsgOrId, SeqId, _MsgProps, IsPersistent, IsDelivered} = M,
               {Filtered1, Delivers1, Acks1, RRC, RB, TC, TB} = Acc) ->
                  case SeqId < TransientThreshold andalso not IsPersistent of
                      true  -> {Filtered1,
                                cons_if(not IsDelivered, SeqId, Delivers1),
                                [SeqId | Acks1], RRC, RB, TC, TB};
                      false -> MsgStatus = m(beta_msg_status(M)),
                               HaveMsg = msg_in_ram(MsgStatus),
                               Size = msg_size(MsgStatus),
                               case is_msg_in_pending_acks(SeqId, State) of
                                   false -> {?QUEUE:in_r(MsgStatus, Filtered1),
                                             Delivers1, Acks1,
                                             RRC + one_if(HaveMsg),
                                             RB + one_if(HaveMsg) * Size,
                                             TC + one_if(not IsPersistent),
                                             TB + one_if(not IsPersistent) * Size};
                                   true  -> Acc %% [0]
                               end
                  end
          end, {?QUEUE:new(), [], [], 0, 0, 0, 0}, List),
    {Filtered, RamReadyCount, RamBytes, DelsAndAcksFun(Delivers, Acks, State),
     TransientCount, TransientBytes}.
%% [0] We don't increase RamBytes here, even though it pertains to
%% unacked messages too, since if HaveMsg then the message must have
%% been stored in the QI, thus the message must have been in
%% qi_pending_ack, thus it must already have been in RAM.

is_msg_in_pending_acks(SeqId, #vqstate { ram_pending_ack  = RPA,
                                         disk_pending_ack = DPA,
                                         qi_pending_ack   = QPA }) ->
    (gb_trees:is_defined(SeqId, RPA) orelse
     gb_trees:is_defined(SeqId, DPA) orelse
     gb_trees:is_defined(SeqId, QPA)).

expand_delta(SeqId, ?BLANK_DELTA_PATTERN(X), IsPersistent) ->
    d(#delta { start_seq_id = SeqId, count = 1, end_seq_id = SeqId + 1,
               transient = one_if(not IsPersistent)});
expand_delta(SeqId, #delta { start_seq_id = StartSeqId,
                             count        = Count,
                             transient    = Transient } = Delta,
             IsPersistent )
  when SeqId < StartSeqId ->
    d(Delta #delta { start_seq_id = SeqId, count = Count + 1,
                     transient = Transient + one_if(not IsPersistent)});
expand_delta(SeqId, #delta { count        = Count,
                             end_seq_id   = EndSeqId,
                             transient    = Transient } = Delta,
             IsPersistent)
  when SeqId >= EndSeqId ->
    d(Delta #delta { count = Count + 1, end_seq_id = SeqId + 1,
                     transient = Transient + one_if(not IsPersistent)});
expand_delta(_SeqId, #delta { count       = Count,
                              transient   = Transient } = Delta,
             IsPersistent ) ->
    d(Delta #delta { count = Count + 1,
                     transient = Transient + one_if(not IsPersistent) }).

%%----------------------------------------------------------------------------
%% Internal major helpers for Public API
%%----------------------------------------------------------------------------

init(IsDurable, IndexState, DeltaCount, DeltaBytes, Terms,
     PersistentClient, TransientClient) ->
    {LowSeqId, NextSeqId, IndexState1} = rabbit_queue_index:bounds(IndexState),

    {DeltaCount1, DeltaBytes1} =
        case Terms of
            non_clean_shutdown -> {DeltaCount, DeltaBytes};
            _                  -> {proplists:get_value(persistent_count,
                                                       Terms, DeltaCount),
                                   proplists:get_value(persistent_bytes,
                                                       Terms, DeltaBytes)}
        end,
    Delta = case DeltaCount1 == 0 andalso DeltaCount /= undefined of
                true  -> ?BLANK_DELTA;
                false -> d(#delta { start_seq_id = LowSeqId,
                                    count        = DeltaCount1,
                                    transient    = 0,
                                    end_seq_id   = NextSeqId })
            end,
    Now = time_compat:monotonic_time(),
    IoBatchSize = rabbit_misc:get_env(rabbit, msg_store_io_batch_size,
                                      ?IO_BATCH_SIZE),

    {ok, IndexMaxSize} = application:get_env(
                           rabbit, queue_index_embed_msgs_below),
    State = #vqstate {
      q1                  = ?QUEUE:new(),
      q2                  = ?QUEUE:new(),
      delta               = Delta,
      q3                  = ?QUEUE:new(),
      q4                  = ?QUEUE:new(),
      next_seq_id         = NextSeqId,
      ram_pending_ack     = gb_trees:empty(),
      disk_pending_ack    = gb_trees:empty(),
      qi_pending_ack      = gb_trees:empty(),
      index_state         = IndexState1,
      msg_store_clients   = {PersistentClient, TransientClient},
      durable             = IsDurable,
      transient_threshold = NextSeqId,
      qi_embed_msgs_below = IndexMaxSize,

      len                 = DeltaCount1,
      persistent_count    = DeltaCount1,
      bytes               = DeltaBytes1,
      persistent_bytes    = DeltaBytes1,
      delta_transient_bytes = 0,

      target_ram_count    = infinity,
      ram_msg_count       = 0,
      ram_msg_count_prev  = 0,
      ram_ack_count_prev  = 0,
      ram_bytes           = 0,
      unacked_bytes       = 0,
      out_counter         = 0,
      in_counter          = 0,
      rates               = blank_rates(Now),
      msgs_on_disk        = gb_sets:new(),
      msg_indices_on_disk = gb_sets:new(),
      unconfirmed         = gb_sets:new(),
      confirmed           = gb_sets:new(),
      ack_out_counter     = 0,
      ack_in_counter      = 0,
      disk_read_count     = 0,
      disk_write_count    = 0,

      io_batch_size       = IoBatchSize,

      mode                = default,
      memory_reduction_run_count = 0},
    a(maybe_deltas_to_betas(State)).

blank_rates(Now) ->
    #rates { in        = 0.0,
             out       = 0.0,
             ack_in    = 0.0,
             ack_out   = 0.0,
             timestamp = Now}.

in_r(MsgStatus = #msg_status { msg = undefined },
     State = #vqstate { mode = default, q3 = Q3, q4 = Q4 }) ->
    case ?QUEUE:is_empty(Q4) of
        true  -> State #vqstate { q3 = ?QUEUE:in_r(MsgStatus, Q3) };
        false -> {Msg, State1 = #vqstate { q4 = Q4a }} =
                     read_msg(MsgStatus, State),
                 MsgStatus1 = MsgStatus#msg_status{msg = Msg},
                 stats(ready0, {MsgStatus, MsgStatus1}, 0,
                       State1 #vqstate { q4 = ?QUEUE:in_r(MsgStatus1, Q4a) })
    end;
in_r(MsgStatus,
     State = #vqstate { mode = default, q4 = Q4 }) ->
    State #vqstate { q4 = ?QUEUE:in_r(MsgStatus, Q4) };
%% lazy queues
in_r(MsgStatus = #msg_status { seq_id = SeqId, is_persistent = IsPersistent },
     State = #vqstate { mode = lazy, q3 = Q3, delta = Delta}) ->
    case ?QUEUE:is_empty(Q3) of
        true  ->
            {_MsgStatus1, State1} =
                maybe_write_to_disk(true, true, MsgStatus, State),
            State2 = stats(ready0, {MsgStatus, none}, 1, State1),
            Delta1 = expand_delta(SeqId, Delta, IsPersistent),
            State2 #vqstate{ delta = Delta1};
        false ->
            State #vqstate { q3 = ?QUEUE:in_r(MsgStatus, Q3) }
    end.

queue_out(State = #vqstate { mode = default, q4 = Q4 }) ->
    case ?QUEUE:out(Q4) of
        {empty, _Q4} ->
            case fetch_from_q3(State) of
                {empty, _State1} = Result     -> Result;
                {loaded, {MsgStatus, State1}} -> {{value, MsgStatus}, State1}
            end;
        {{value, MsgStatus}, Q4a} ->
            {{value, MsgStatus}, State #vqstate { q4 = Q4a }}
    end;
%% lazy queues
queue_out(State = #vqstate { mode = lazy }) ->
    case fetch_from_q3(State) of
        {empty, _State1} = Result     -> Result;
        {loaded, {MsgStatus, State1}} -> {{value, MsgStatus}, State1}
    end.

read_msg(#msg_status{msg           = undefined,
                     msg_id        = MsgId,
                     is_persistent = IsPersistent}, State) ->
    read_msg(MsgId, IsPersistent, State);
read_msg(#msg_status{msg = Msg}, State) ->
    {Msg, State}.

read_msg(MsgId, IsPersistent, State = #vqstate{msg_store_clients = MSCState,
                                               disk_read_count   = Count}) ->
    {{ok, Msg = #basic_message {}}, MSCState1} =
        msg_store_read(MSCState, IsPersistent, MsgId),
    {Msg, State #vqstate {msg_store_clients = MSCState1,
                          disk_read_count   = Count + 1}}.

stats(Signs, Statuses, DeltaPaged, State) ->
    stats0(expand_signs(Signs), expand_statuses(Statuses), DeltaPaged, State).

expand_signs(ready0)        -> {0, 0, true};
expand_signs(lazy_pub)      -> {1, 0, true};
expand_signs({A, B})        -> {A, B, false}.

expand_statuses({none, A})    -> {false,         msg_in_ram(A), A};
expand_statuses({B,    none}) -> {msg_in_ram(B), false,         B};
expand_statuses({lazy, A})    -> {false        , false,         A};
expand_statuses({B,    A})    -> {msg_in_ram(B), msg_in_ram(A), B}.

%% In this function at least, we are religious: the variable name
%% contains "Ready" or "Unacked" iff that is what it counts. If
%% neither is present it counts both.
stats0({DeltaReady, DeltaUnacked, ReadyMsgPaged},
       {InRamBefore, InRamAfter, MsgStatus}, DeltaPaged,
       State = #vqstate{len              = ReadyCount,
                        bytes            = ReadyBytes,
                        ram_msg_count    = RamReadyCount,
                        persistent_count = PersistentCount,
                        unacked_bytes    = UnackedBytes,
                        ram_bytes        = RamBytes,
                        delta_transient_bytes = DeltaBytes,
                        persistent_bytes = PersistentBytes}) ->
    S = msg_size(MsgStatus),
    DeltaTotal = DeltaReady + DeltaUnacked,
    DeltaRam = case {InRamBefore, InRamAfter} of
                   {false, false} ->  0;
                   {false, true}  ->  1;
                   {true,  false} -> -1;
                   {true,  true}  ->  0
               end,
    DeltaRamReady = case DeltaReady of
                        1                    -> one_if(InRamAfter);
                        -1                   -> -one_if(InRamBefore);
                        0 when ReadyMsgPaged -> DeltaRam;
                        0                    -> 0
                    end,
    DeltaPersistent = DeltaTotal * one_if(MsgStatus#msg_status.is_persistent),
    State#vqstate{len               = ReadyCount      + DeltaReady,
                  ram_msg_count     = RamReadyCount   + DeltaRamReady,
                  persistent_count  = PersistentCount + DeltaPersistent,
                  bytes             = ReadyBytes      + DeltaReady       * S,
                  unacked_bytes     = UnackedBytes    + DeltaUnacked     * S,
                  ram_bytes         = RamBytes        + DeltaRam         * S,
                  persistent_bytes  = PersistentBytes + DeltaPersistent  * S,
                  delta_transient_bytes = DeltaBytes  + DeltaPaged * one_if(not MsgStatus#msg_status.is_persistent) * S}.

msg_size(#msg_status{msg_props = #message_properties{size = Size}}) -> Size.

msg_in_ram(#msg_status{msg = Msg}) -> Msg =/= undefined.

%% first param: AckRequired
remove(true, MsgStatus = #msg_status {
               seq_id        = SeqId,
               is_delivered  = IsDelivered,
               index_on_disk = IndexOnDisk },
       State = #vqstate {out_counter       = OutCount,
                         index_state       = IndexState}) ->
    %% Mark it delivered if necessary
    IndexState1 = maybe_write_delivered(
                    IndexOnDisk andalso not IsDelivered,
                    SeqId, IndexState),

    State1 = record_pending_ack(
               MsgStatus #msg_status {
                 is_delivered = true }, State),

    State2 = stats({-1, 1}, {MsgStatus, MsgStatus}, 0, State1),

    {SeqId, maybe_update_rates(
              State2 #vqstate {out_counter = OutCount + 1,
                               index_state = IndexState1})};

%% This function body has the same behaviour as remove_queue_entries/3
%% but instead of removing messages based on a ?QUEUE, this removes
%% just one message, the one referenced by the MsgStatus provided.
remove(false, MsgStatus = #msg_status {
                seq_id        = SeqId,
                msg_id        = MsgId,
                is_persistent = IsPersistent,
                is_delivered  = IsDelivered,
                msg_in_store  = MsgInStore,
                index_on_disk = IndexOnDisk },
       State = #vqstate {out_counter       = OutCount,
                         index_state       = IndexState,
                         msg_store_clients = MSCState}) ->
    %% Mark it delivered if necessary
    IndexState1 = maybe_write_delivered(
                    IndexOnDisk andalso not IsDelivered,
                    SeqId, IndexState),

    %% Remove from msg_store and queue index, if necessary
    case MsgInStore of
        true  -> ok = msg_store_remove(MSCState, IsPersistent, [MsgId]);
        false -> ok
    end,

    IndexState2 =
        case IndexOnDisk of
            true  -> rabbit_queue_index:ack([SeqId], IndexState1);
            false -> IndexState1
        end,

    State1 = stats({-1, 0}, {MsgStatus, none}, 0, State),

    {undefined, maybe_update_rates(
                  State1 #vqstate {out_counter = OutCount + 1,
                                   index_state = IndexState2})}.

%% This function exists as a way to improve dropwhile/2
%% performance. The idea of having this function is to optimise calls
%% to rabbit_queue_index by batching delivers and acks, instead of
%% sending them one by one.
%%
%% Instead of removing every message as their are popped from the
%% queue, it first accumulates them and then removes them by calling
%% remove_queue_entries/3, since the behaviour of
%% remove_queue_entries/3 when used with
%% process_delivers_and_acks_fun(deliver_and_ack) is the same as
%% calling remove(false, MsgStatus, State).
%%
%% remove/3 also updates the out_counter in every call, but here we do
%% it just once at the end.
remove_by_predicate(Pred, State = #vqstate {out_counter = OutCount}) ->
    {MsgProps, QAcc, State1} =
        collect_by_predicate(Pred, ?QUEUE:new(), State),
    State2 =
        remove_queue_entries(
          QAcc, process_delivers_and_acks_fun(deliver_and_ack), State1),
    %% maybe_update_rates/1 is called in remove/2 for every
    %% message. Since we update out_counter only once, we call it just
    %% there.
    {MsgProps, maybe_update_rates(
                 State2 #vqstate {
                   out_counter = OutCount + ?QUEUE:len(QAcc)})}.

%% This function exists as a way to improve fetchwhile/4
%% performance. The idea of having this function is to optimise calls
%% to rabbit_queue_index by batching delivers, instead of sending them
%% one by one.
%%
%% Fun is the function passed to fetchwhile/4 that's
%% applied to every fetched message and used to build the fetchwhile/4
%% result accumulator FetchAcc.
fetch_by_predicate(Pred, Fun, FetchAcc,
                   State = #vqstate {
                              index_state = IndexState,
                              out_counter = OutCount}) ->
    {MsgProps, QAcc, State1} =
        collect_by_predicate(Pred, ?QUEUE:new(), State),

    {Delivers, FetchAcc1, State2} =
        process_queue_entries(QAcc, Fun, FetchAcc, State1),

    IndexState1 = rabbit_queue_index:deliver(Delivers, IndexState),

    {MsgProps, FetchAcc1, maybe_update_rates(
                            State2 #vqstate {
                              index_state = IndexState1,
                              out_counter = OutCount + ?QUEUE:len(QAcc)})}.

%% We try to do here the same as what remove(true, State) does but
%% processing several messages at the same time. The idea is to
%% optimize rabbit_queue_index:deliver/2 calls by sending a list of
%% SeqIds instead of one by one, thus process_queue_entries1 will
%% accumulate the required deliveries, will record_pending_ack for
%% each message, and will update stats, like remove/2 does.
%%
%% For the meaning of Fun and FetchAcc arguments see
%% fetch_by_predicate/4 above.
process_queue_entries(Q, Fun, FetchAcc, State) ->
    ?QUEUE:foldl(fun (MsgStatus, Acc) ->
                         process_queue_entries1(MsgStatus, Fun, Acc)
                 end,
                 {[], FetchAcc, State}, Q).

process_queue_entries1(
  #msg_status { seq_id = SeqId, is_delivered = IsDelivered,
                index_on_disk = IndexOnDisk} = MsgStatus,
  Fun,
  {Delivers, FetchAcc, State}) ->
    {Msg, State1} = read_msg(MsgStatus, State),
    State2 = record_pending_ack(
               MsgStatus #msg_status {
                 is_delivered = true }, State1),
    {cons_if(IndexOnDisk andalso not IsDelivered, SeqId, Delivers),
     Fun(Msg, SeqId, FetchAcc),
     stats({-1, 1}, {MsgStatus, MsgStatus}, 0, State2)}.

collect_by_predicate(Pred, QAcc, State) ->
    case queue_out(State) of
        {empty, State1} ->
            {undefined, QAcc, State1};
        {{value, MsgStatus = #msg_status { msg_props = MsgProps }}, State1} ->
            case Pred(MsgProps) of
                true  -> collect_by_predicate(Pred, ?QUEUE:in(MsgStatus, QAcc),
                                              State1);
                false -> {MsgProps, QAcc, in_r(MsgStatus, State1)}
            end
    end.

%%----------------------------------------------------------------------------
%% Helpers for Public API purge/1 function
%%----------------------------------------------------------------------------

%% The difference between purge_when_pending_acks/1
%% vs. purge_and_index_reset/1 is that the first one issues a deliver
%% and an ack to the queue index for every message that's being
%% removed, while the later just resets the queue index state.
purge_when_pending_acks(State) ->
    State1 = purge1(process_delivers_and_acks_fun(deliver_and_ack), State),
    a(State1).

purge_and_index_reset(State) ->
    State1 = purge1(process_delivers_and_acks_fun(none), State),
    a(reset_qi_state(State1)).

%% This function removes messages from each of {q1, q2, q3, q4}.
%%
%% With remove_queue_entries/3 q1 and q4 are emptied, while q2 and q3
%% are specially handled by purge_betas_and_deltas/2.
%%
%% purge_betas_and_deltas/2 loads messages from the queue index,
%% filling up q3 and in some cases moving messages form q2 to q3 while
%% reseting q2 to an empty queue (see maybe_deltas_to_betas/2). The
%% messages loaded into q3 are removed by calling
%% remove_queue_entries/3 until there are no more messages to be read
%% from the queue index. Messages are read in batches from the queue
%% index.
purge1(AfterFun, State = #vqstate { q4 = Q4}) ->
    State1 = remove_queue_entries(Q4, AfterFun, State),

    State2 = #vqstate {q1 = Q1} =
        purge_betas_and_deltas(AfterFun, State1#vqstate{q4 = ?QUEUE:new()}),

    State3 = remove_queue_entries(Q1, AfterFun, State2),

    a(State3#vqstate{q1 = ?QUEUE:new()}).

reset_qi_state(State = #vqstate{index_state = IndexState}) ->
    State#vqstate{index_state =
                         rabbit_queue_index:reset_state(IndexState)}.

is_pending_ack_empty(State) ->
    count_pending_acks(State) =:= 0.

is_unconfirmed_empty(#vqstate { unconfirmed = UC }) ->
    gb_sets:is_empty(UC).

count_pending_acks(#vqstate { ram_pending_ack   = RPA,
                              disk_pending_ack  = DPA,
                              qi_pending_ack    = QPA }) ->
    gb_trees:size(RPA) + gb_trees:size(DPA) + gb_trees:size(QPA).

purge_betas_and_deltas(DelsAndAcksFun, State = #vqstate { mode = Mode }) ->
    State0 = #vqstate { q3 = Q3 } =
        case Mode of
            lazy -> maybe_deltas_to_betas(DelsAndAcksFun, State);
            _    -> State
        end,

    case ?QUEUE:is_empty(Q3) of
        true  -> State0;
        false -> State1 = remove_queue_entries(Q3, DelsAndAcksFun, State0),
                 purge_betas_and_deltas(DelsAndAcksFun,
                                        maybe_deltas_to_betas(
                                          DelsAndAcksFun,
                                          State1#vqstate{q3 = ?QUEUE:new()}))
    end.

remove_queue_entries(Q, DelsAndAcksFun,
                     State = #vqstate{msg_store_clients = MSCState}) ->
    {MsgIdsByStore, Delivers, Acks, State1} =
        ?QUEUE:foldl(fun remove_queue_entries1/2,
                     {orddict:new(), [], [], State}, Q),
    remove_msgs_by_id(MsgIdsByStore, MSCState),
    DelsAndAcksFun(Delivers, Acks, State1).

remove_queue_entries1(
  #msg_status { msg_id = MsgId, seq_id = SeqId, is_delivered = IsDelivered,
                msg_in_store = MsgInStore, index_on_disk = IndexOnDisk,
                is_persistent = IsPersistent} = MsgStatus,
  {MsgIdsByStore, Delivers, Acks, State}) ->
    {case MsgInStore of
         true  -> rabbit_misc:orddict_cons(IsPersistent, MsgId, MsgIdsByStore);
         false -> MsgIdsByStore
     end,
     cons_if(IndexOnDisk andalso not IsDelivered, SeqId, Delivers),
     cons_if(IndexOnDisk, SeqId, Acks),
     stats({-1, 0}, {MsgStatus, none}, 0, State)}.

process_delivers_and_acks_fun(deliver_and_ack) ->
    fun (Delivers, Acks, State = #vqstate { index_state = IndexState }) ->
            IndexState1 =
                rabbit_queue_index:ack(
                  Acks, rabbit_queue_index:deliver(Delivers, IndexState)),
            State #vqstate { index_state = IndexState1 }
    end;
process_delivers_and_acks_fun(_) ->
    fun (_, _, State) ->
            State
    end.

%%----------------------------------------------------------------------------
%% Internal gubbins for publishing
%%----------------------------------------------------------------------------

publish1(Msg = #basic_message { is_persistent = IsPersistent, id = MsgId },
         MsgProps = #message_properties { needs_confirming = NeedsConfirming },
         IsDelivered, _ChPid, _Flow, PersistFun,
         State = #vqstate { q1 = Q1, q3 = Q3, q4 = Q4,
                            mode                = default,
                            qi_embed_msgs_below = IndexMaxSize,
                            next_seq_id         = SeqId,
                            in_counter          = InCount,
                            durable             = IsDurable,
                            unconfirmed         = UC }) ->
    IsPersistent1 = IsDurable andalso IsPersistent,
    MsgStatus = msg_status(IsPersistent1, IsDelivered, SeqId, Msg, MsgProps, IndexMaxSize),
    {MsgStatus1, State1} = PersistFun(false, false, MsgStatus, State),
    State2 = case ?QUEUE:is_empty(Q3) of
                 false -> State1 #vqstate { q1 = ?QUEUE:in(m(MsgStatus1), Q1) };
                 true  -> State1 #vqstate { q4 = ?QUEUE:in(m(MsgStatus1), Q4) }
             end,
    InCount1 = InCount + 1,
    UC1 = gb_sets_maybe_insert(NeedsConfirming, MsgId, UC),
    stats({1, 0}, {none, MsgStatus1}, 0,
          State2#vqstate{ next_seq_id = SeqId + 1,
                          in_counter  = InCount1,
                          unconfirmed = UC1 });
publish1(Msg = #basic_message { is_persistent = IsPersistent, id = MsgId },
             MsgProps = #message_properties { needs_confirming = NeedsConfirming },
             IsDelivered, _ChPid, _Flow, PersistFun,
             State = #vqstate { mode                = lazy,
                                qi_embed_msgs_below = IndexMaxSize,
                                next_seq_id         = SeqId,
                                in_counter          = InCount,
                                durable             = IsDurable,
                                unconfirmed         = UC,
                                delta               = Delta}) ->
    IsPersistent1 = IsDurable andalso IsPersistent,
    MsgStatus = msg_status(IsPersistent1, IsDelivered, SeqId, Msg, MsgProps, IndexMaxSize),
    {MsgStatus1, State1} = PersistFun(true, true, MsgStatus, State),
    Delta1 = expand_delta(SeqId, Delta, IsPersistent),
    UC1 = gb_sets_maybe_insert(NeedsConfirming, MsgId, UC),
    stats(lazy_pub, {lazy, m(MsgStatus1)}, 1,
          State1#vqstate{ delta       = Delta1,
                          next_seq_id = SeqId + 1,
                          in_counter  = InCount + 1,
                          unconfirmed = UC1}).

batch_publish1({Msg, MsgProps, IsDelivered}, {ChPid, Flow, State}) ->
    {ChPid, Flow, publish1(Msg, MsgProps, IsDelivered, ChPid, Flow,
                           fun maybe_prepare_write_to_disk/4, State)}.

publish_delivered1(Msg = #basic_message { is_persistent = IsPersistent,
                                          id = MsgId },
                   MsgProps = #message_properties {
                                 needs_confirming = NeedsConfirming },
                   _ChPid, _Flow, PersistFun,
                   State = #vqstate { mode                = default,
                                      qi_embed_msgs_below = IndexMaxSize,
                                      next_seq_id         = SeqId,
                                      out_counter         = OutCount,
                                      in_counter          = InCount,
                                      durable             = IsDurable,
                                      unconfirmed         = UC }) ->
    IsPersistent1 = IsDurable andalso IsPersistent,
    MsgStatus = msg_status(IsPersistent1, true, SeqId, Msg, MsgProps, IndexMaxSize),
    {MsgStatus1, State1} = PersistFun(false, false, MsgStatus, State),
    State2 = record_pending_ack(m(MsgStatus1), State1),
    UC1 = gb_sets_maybe_insert(NeedsConfirming, MsgId, UC),
    State3 = stats({0, 1}, {none, MsgStatus1}, 0,
                   State2 #vqstate { next_seq_id      = SeqId    + 1,
                                     out_counter      = OutCount + 1,
                                     in_counter       = InCount  + 1,
                                     unconfirmed      = UC1 }),
    {SeqId, State3};
publish_delivered1(Msg = #basic_message { is_persistent = IsPersistent,
                                          id = MsgId },
                   MsgProps = #message_properties {
                                 needs_confirming = NeedsConfirming },
                   _ChPid, _Flow, PersistFun,
                   State = #vqstate { mode                = lazy,
                                      qi_embed_msgs_below = IndexMaxSize,
                                      next_seq_id         = SeqId,
                                      out_counter         = OutCount,
                                      in_counter          = InCount,
                                      durable             = IsDurable,
                                      unconfirmed         = UC }) ->
    IsPersistent1 = IsDurable andalso IsPersistent,
    MsgStatus = msg_status(IsPersistent1, true, SeqId, Msg, MsgProps, IndexMaxSize),
    {MsgStatus1, State1} = PersistFun(true, true, MsgStatus, State),
    State2 = record_pending_ack(m(MsgStatus1), State1),
    UC1 = gb_sets_maybe_insert(NeedsConfirming, MsgId, UC),
    State3 = stats({0, 1}, {none, MsgStatus1}, 0,
                   State2 #vqstate { next_seq_id      = SeqId    + 1,
                                     out_counter      = OutCount + 1,
                                     in_counter       = InCount  + 1,
                                     unconfirmed      = UC1 }),
    {SeqId, State3}.

batch_publish_delivered1({Msg, MsgProps}, {ChPid, Flow, SeqIds, State}) ->
    {SeqId, State1} =
        publish_delivered1(Msg, MsgProps, ChPid, Flow,
                           fun maybe_prepare_write_to_disk/4,
                           State),
    {ChPid, Flow, [SeqId | SeqIds], State1}.

maybe_write_msg_to_disk(_Force, MsgStatus = #msg_status {
                                  msg_in_store = true }, State) ->
    {MsgStatus, State};
maybe_write_msg_to_disk(Force, MsgStatus = #msg_status {
                                 msg = Msg, msg_id = MsgId,
                                 is_persistent = IsPersistent },
                        State = #vqstate{ msg_store_clients = MSCState,
                                          disk_write_count  = Count})
  when Force orelse IsPersistent ->
    case persist_to(MsgStatus) of
        msg_store   -> ok = msg_store_write(MSCState, IsPersistent, MsgId,
                                            prepare_to_store(Msg)),
                       {MsgStatus#msg_status{msg_in_store = true},
                        State#vqstate{disk_write_count = Count + 1}};
        queue_index -> {MsgStatus, State}
    end;
maybe_write_msg_to_disk(_Force, MsgStatus, State) ->
    {MsgStatus, State}.

%% Due to certain optimizations made inside
%% rabbit_queue_index:pre_publish/7 we need to have two separate
%% functions for index persistence. This one is only used when paging
%% during memory pressure. We didn't want to modify
%% maybe_write_index_to_disk/3 because that function is used in other
%% places.
maybe_batch_write_index_to_disk(_Force,
                                MsgStatus = #msg_status {
                                  index_on_disk = true }, State) ->
    {MsgStatus, State};
maybe_batch_write_index_to_disk(Force,
                                MsgStatus = #msg_status {
                                  msg           = Msg,
                                  msg_id        = MsgId,
                                  seq_id        = SeqId,
                                  is_persistent = IsPersistent,
                                  is_delivered  = IsDelivered,
                                  msg_props     = MsgProps},
                                State = #vqstate {
                                           target_ram_count = TargetRamCount,
                                           disk_write_count = DiskWriteCount,
                                           index_state      = IndexState})
  when Force orelse IsPersistent ->
    {MsgOrId, DiskWriteCount1} =
        case persist_to(MsgStatus) of
            msg_store   -> {MsgId, DiskWriteCount};
            queue_index -> {prepare_to_store(Msg), DiskWriteCount + 1}
        end,
    IndexState1 = rabbit_queue_index:pre_publish(
                    MsgOrId, SeqId, MsgProps, IsPersistent, IsDelivered,
                    TargetRamCount, IndexState),
    {MsgStatus#msg_status{index_on_disk = true},
     State#vqstate{index_state      = IndexState1,
                   disk_write_count = DiskWriteCount1}};
maybe_batch_write_index_to_disk(_Force, MsgStatus, State) ->
    {MsgStatus, State}.

maybe_write_index_to_disk(_Force, MsgStatus = #msg_status {
                                    index_on_disk = true }, State) ->
    {MsgStatus, State};
maybe_write_index_to_disk(Force, MsgStatus = #msg_status {
                                   msg           = Msg,
                                   msg_id        = MsgId,
                                   seq_id        = SeqId,
                                   is_persistent = IsPersistent,
                                   is_delivered  = IsDelivered,
                                   msg_props     = MsgProps},
                          State = #vqstate{target_ram_count = TargetRamCount,
                                           disk_write_count = DiskWriteCount,
                                           index_state      = IndexState})
  when Force orelse IsPersistent ->
    {MsgOrId, DiskWriteCount1} =
        case persist_to(MsgStatus) of
            msg_store   -> {MsgId, DiskWriteCount};
            queue_index -> {prepare_to_store(Msg), DiskWriteCount + 1}
        end,
    IndexState1 = rabbit_queue_index:publish(
                    MsgOrId, SeqId, MsgProps, IsPersistent, TargetRamCount,
                    IndexState),
    IndexState2 = maybe_write_delivered(IsDelivered, SeqId, IndexState1),
    {MsgStatus#msg_status{index_on_disk = true},
     State#vqstate{index_state      = IndexState2,
                   disk_write_count = DiskWriteCount1}};

maybe_write_index_to_disk(_Force, MsgStatus, State) ->
    {MsgStatus, State}.

maybe_write_to_disk(ForceMsg, ForceIndex, MsgStatus, State) ->
    {MsgStatus1, State1} = maybe_write_msg_to_disk(ForceMsg, MsgStatus, State),
    maybe_write_index_to_disk(ForceIndex, MsgStatus1, State1).

maybe_prepare_write_to_disk(ForceMsg, ForceIndex, MsgStatus, State) ->
    {MsgStatus1, State1} = maybe_write_msg_to_disk(ForceMsg, MsgStatus, State),
    maybe_batch_write_index_to_disk(ForceIndex, MsgStatus1, State1).

determine_persist_to(#basic_message{
                        content = #content{properties     = Props,
                                           properties_bin = PropsBin}},
                     #message_properties{size = BodySize},
                     IndexMaxSize) ->
    %% The >= is so that you can set the env to 0 and never persist
    %% to the index.
    %%
    %% We want this to be fast, so we avoid size(term_to_binary())
    %% here, or using the term size estimation from truncate.erl, both
    %% of which are too slow. So instead, if the message body size
    %% goes over the limit then we avoid any other checks.
    %%
    %% If it doesn't we need to decide if the properties will push
    %% it past the limit. If we have the encoded properties (usual
    %% case) we can just check their size. If we don't (message came
    %% via the direct client), we make a guess based on the number of
    %% headers.
    case BodySize >= IndexMaxSize of
        true  -> msg_store;
        false -> Est = case is_binary(PropsBin) of
                           true  -> BodySize + size(PropsBin);
                           false -> #'P_basic'{headers = Hs} = Props,
                                    case Hs of
                                        undefined -> 0;
                                        _         -> length(Hs)
                                    end * ?HEADER_GUESS_SIZE + BodySize
                       end,
                 case Est >= IndexMaxSize of
                     true  -> msg_store;
                     false -> queue_index
                 end
    end.

persist_to(#msg_status{persist_to = To}) -> To.

prepare_to_store(Msg) ->
    Msg#basic_message{
      %% don't persist any recoverable decoded properties
      content = rabbit_binary_parser:clear_decoded_content(
                  Msg #basic_message.content)}.

%%----------------------------------------------------------------------------
%% Internal gubbins for acks
%%----------------------------------------------------------------------------

record_pending_ack(#msg_status { seq_id = SeqId } = MsgStatus,
                   State = #vqstate { ram_pending_ack  = RPA,
                                      disk_pending_ack = DPA,
                                      qi_pending_ack   = QPA,
                                      ack_in_counter   = AckInCount}) ->
    Insert = fun (Tree) -> gb_trees:insert(SeqId, MsgStatus, Tree) end,
    {RPA1, DPA1, QPA1} =
        case {msg_in_ram(MsgStatus), persist_to(MsgStatus)} of
            {false, _}           -> {RPA, Insert(DPA), QPA};
            {_,     queue_index} -> {RPA, DPA, Insert(QPA)};
            {_,     msg_store}   -> {Insert(RPA), DPA, QPA}
        end,
    State #vqstate { ram_pending_ack  = RPA1,
                     disk_pending_ack = DPA1,
                     qi_pending_ack   = QPA1,
                     ack_in_counter   = AckInCount + 1}.

lookup_pending_ack(SeqId, #vqstate { ram_pending_ack  = RPA,
                                     disk_pending_ack = DPA,
                                     qi_pending_ack   = QPA}) ->
    case gb_trees:lookup(SeqId, RPA) of
        {value, V} -> V;
        none       -> case gb_trees:lookup(SeqId, DPA) of
                          {value, V} -> V;
                          none       -> gb_trees:get(SeqId, QPA)
                      end
    end.

%% First parameter = UpdateStats
remove_pending_ack(true, SeqId, State) ->
    case remove_pending_ack(false, SeqId, State) of
        {none, _} ->
            {none, State};
        {MsgStatus, State1} ->
            {MsgStatus, stats({0, -1}, {MsgStatus, none}, 0, State1)}
    end;
remove_pending_ack(false, SeqId, State = #vqstate{ram_pending_ack  = RPA,
                                                  disk_pending_ack = DPA,
                                                  qi_pending_ack   = QPA}) ->
    case gb_trees:lookup(SeqId, RPA) of
        {value, V} -> RPA1 = gb_trees:delete(SeqId, RPA),
                      {V, State #vqstate { ram_pending_ack = RPA1 }};
        none       -> case gb_trees:lookup(SeqId, DPA) of
                          {value, V} ->
                              DPA1 = gb_trees:delete(SeqId, DPA),
                              {V, State#vqstate{disk_pending_ack = DPA1}};
                          none ->
                              case gb_trees:lookup(SeqId, QPA) of
                                  {value, V} ->
                                      QPA1 = gb_trees:delete(SeqId, QPA),
                                      {V, State#vqstate{qi_pending_ack = QPA1}};
                                  none ->
                                      {none, State}
                              end
                      end
    end.

purge_pending_ack(KeepPersistent,
                  State = #vqstate { index_state       = IndexState,
                                     msg_store_clients = MSCState }) ->
    {IndexOnDiskSeqIds, MsgIdsByStore, State1} = purge_pending_ack1(State),
    case KeepPersistent of
        true  -> remove_transient_msgs_by_id(MsgIdsByStore, MSCState),
                 State1;
        false -> IndexState1 =
                     rabbit_queue_index:ack(IndexOnDiskSeqIds, IndexState),
                 remove_msgs_by_id(MsgIdsByStore, MSCState),
                 State1 #vqstate { index_state = IndexState1 }
    end.

purge_pending_ack_delete_and_terminate(
  State = #vqstate { index_state       = IndexState,
                     msg_store_clients = MSCState }) ->
    {_, MsgIdsByStore, State1} = purge_pending_ack1(State),
    IndexState1 = rabbit_queue_index:delete_and_terminate(IndexState),
    remove_msgs_by_id(MsgIdsByStore, MSCState),
    State1 #vqstate { index_state = IndexState1 }.

purge_pending_ack1(State = #vqstate { ram_pending_ack   = RPA,
                                      disk_pending_ack  = DPA,
                                      qi_pending_ack    = QPA }) ->
    F = fun (_SeqId, MsgStatus, Acc) -> accumulate_ack(MsgStatus, Acc) end,
    {IndexOnDiskSeqIds, MsgIdsByStore, _AllMsgIds} =
        rabbit_misc:gb_trees_fold(
          F, rabbit_misc:gb_trees_fold(
               F,  rabbit_misc:gb_trees_fold(
                     F, accumulate_ack_init(), RPA), DPA), QPA),
    State1 = State #vqstate { ram_pending_ack  = gb_trees:empty(),
                              disk_pending_ack = gb_trees:empty(),
                              qi_pending_ack   = gb_trees:empty()},
    {IndexOnDiskSeqIds, MsgIdsByStore, State1}.

%% MsgIdsByStore is an orddict with two keys:
%%
%% true: holds a list of Persistent Message Ids.
%% false: holds a list of Transient Message Ids.
%%
%% When we call orddict:to_list/1 we get two sets of msg ids, where
%% IsPersistent is either true for persistent messages or false for
%% transient ones. The msg_store_remove/3 function takes this boolean
%% flag to determine from which store the messages should be removed
%% from.
remove_msgs_by_id(MsgIdsByStore, MSCState) ->
    [ok = msg_store_remove(MSCState, IsPersistent, MsgIds)
     || {IsPersistent, MsgIds} <- orddict:to_list(MsgIdsByStore)].

remove_transient_msgs_by_id(MsgIdsByStore, MSCState) ->
    case orddict:find(false, MsgIdsByStore) of
        error        -> ok;
        {ok, MsgIds} -> ok = msg_store_remove(MSCState, false, MsgIds)
    end.

accumulate_ack_init() -> {[], orddict:new(), []}.

accumulate_ack(#msg_status { seq_id        = SeqId,
                             msg_id        = MsgId,
                             is_persistent = IsPersistent,
                             msg_in_store  = MsgInStore,
                             index_on_disk = IndexOnDisk },
               {IndexOnDiskSeqIdsAcc, MsgIdsByStore, AllMsgIds}) ->
    {cons_if(IndexOnDisk, SeqId, IndexOnDiskSeqIdsAcc),
     case MsgInStore of
         true  -> rabbit_misc:orddict_cons(IsPersistent, MsgId, MsgIdsByStore);
         false -> MsgIdsByStore
     end,
     [MsgId | AllMsgIds]}.

%%----------------------------------------------------------------------------
%% Internal plumbing for confirms (aka publisher acks)
%%----------------------------------------------------------------------------

record_confirms(MsgIdSet, State = #vqstate { msgs_on_disk        = MOD,
                                             msg_indices_on_disk = MIOD,
                                             unconfirmed         = UC,
                                             confirmed           = C }) ->
    State #vqstate {
      msgs_on_disk        = rabbit_misc:gb_sets_difference(MOD,  MsgIdSet),
      msg_indices_on_disk = rabbit_misc:gb_sets_difference(MIOD, MsgIdSet),
      unconfirmed         = rabbit_misc:gb_sets_difference(UC,   MsgIdSet),
      confirmed           = gb_sets:union(C, MsgIdSet) }.

msgs_written_to_disk(Callback, MsgIdSet, ignored) ->
    Callback(?MODULE,
             fun (?MODULE, State) -> record_confirms(MsgIdSet, State) end);
msgs_written_to_disk(Callback, MsgIdSet, written) ->
    Callback(?MODULE,
             fun (?MODULE, State = #vqstate { msgs_on_disk        = MOD,
                                              msg_indices_on_disk = MIOD,
                                              unconfirmed         = UC }) ->
                     Confirmed = gb_sets:intersection(UC, MsgIdSet),
                     record_confirms(gb_sets:intersection(MsgIdSet, MIOD),
                                     State #vqstate {
                                       msgs_on_disk =
                                           gb_sets:union(MOD, Confirmed) })
             end).

msg_indices_written_to_disk(Callback, MsgIdSet) ->
    Callback(?MODULE,
             fun (?MODULE, State = #vqstate { msgs_on_disk        = MOD,
                                              msg_indices_on_disk = MIOD,
                                              unconfirmed         = UC }) ->
                     Confirmed = gb_sets:intersection(UC, MsgIdSet),
                     record_confirms(gb_sets:intersection(MsgIdSet, MOD),
                                     State #vqstate {
                                       msg_indices_on_disk =
                                           gb_sets:union(MIOD, Confirmed) })
             end).

msgs_and_indices_written_to_disk(Callback, MsgIdSet) ->
    Callback(?MODULE,
             fun (?MODULE, State) -> record_confirms(MsgIdSet, State) end).

%%----------------------------------------------------------------------------
%% Internal plumbing for requeue
%%----------------------------------------------------------------------------

publish_alpha(#msg_status { msg = undefined } = MsgStatus, State) ->
    {Msg, State1} = read_msg(MsgStatus, State),
    MsgStatus1 = MsgStatus#msg_status { msg = Msg },
    {MsgStatus1, stats({1, -1}, {MsgStatus, MsgStatus1}, 0, State1)};
publish_alpha(MsgStatus, State) ->
    {MsgStatus, stats({1, -1}, {MsgStatus, MsgStatus}, 0, State)}.

publish_beta(MsgStatus, State) ->
    {MsgStatus1, State1} = maybe_prepare_write_to_disk(true, false, MsgStatus, State),
    MsgStatus2 = m(trim_msg_status(MsgStatus1)),
    {MsgStatus2, stats({1, -1}, {MsgStatus, MsgStatus2}, 0, State1)}.

%% Rebuild queue, inserting sequence ids to maintain ordering
queue_merge(SeqIds, Q, MsgIds, Limit, PubFun, State) ->
    queue_merge(SeqIds, Q, ?QUEUE:new(), MsgIds,
                Limit, PubFun, State).

queue_merge([SeqId | Rest] = SeqIds, Q, Front, MsgIds,
            Limit, PubFun, State)
  when Limit == undefined orelse SeqId < Limit ->
    case ?QUEUE:out(Q) of
        {{value, #msg_status { seq_id = SeqIdQ } = MsgStatus}, Q1}
          when SeqIdQ < SeqId ->
            %% enqueue from the remaining queue
            queue_merge(SeqIds, Q1, ?QUEUE:in(MsgStatus, Front), MsgIds,
                        Limit, PubFun, State);
        {_, _Q1} ->
            %% enqueue from the remaining list of sequence ids
            case msg_from_pending_ack(SeqId, State) of
                {none, _} ->
                    queue_merge(Rest, Q, Front, MsgIds, Limit, PubFun, State);
                {MsgStatus, State1} ->
                    {#msg_status { msg_id = MsgId } = MsgStatus1, State2} =
                        PubFun(MsgStatus, State1),
                    queue_merge(Rest, Q, ?QUEUE:in(MsgStatus1, Front), [MsgId | MsgIds],
                                Limit, PubFun, State2)
            end
    end;
queue_merge(SeqIds, Q, Front, MsgIds,
            _Limit, _PubFun, State) ->
    {SeqIds, ?QUEUE:join(Front, Q), MsgIds, State}.

delta_merge([], Delta, MsgIds, State) ->
    {Delta, MsgIds, State};
delta_merge(SeqIds, Delta, MsgIds, State) ->
    lists:foldl(fun (SeqId, {Delta0, MsgIds0, State0} = Acc) ->
                        case msg_from_pending_ack(SeqId, State0) of
                            {none, _} ->
                                Acc;
                        {#msg_status { msg_id = MsgId,
                                       is_persistent = IsPersistent } = MsgStatus, State1} ->
                                {_MsgStatus, State2} =
                                    maybe_prepare_write_to_disk(true, true, MsgStatus, State1),
                                {expand_delta(SeqId, Delta0, IsPersistent), [MsgId | MsgIds0],
                                 stats({1, -1}, {MsgStatus, none}, 1, State2)}
                        end
                end, {Delta, MsgIds, State}, SeqIds).

%% Mostly opposite of record_pending_ack/2
msg_from_pending_ack(SeqId, State) ->
    case remove_pending_ack(false, SeqId, State) of
        {none, _} ->
            {none, State};
        {#msg_status { msg_props = MsgProps } = MsgStatus, State1} ->
            {MsgStatus #msg_status {
               msg_props = MsgProps #message_properties { needs_confirming = false } },
             State1}
    end.

beta_limit(Q) ->
    case ?QUEUE:peek(Q) of
        {value, #msg_status { seq_id = SeqId }} -> SeqId;
        empty                                   -> undefined
    end.

delta_limit(?BLANK_DELTA_PATTERN(_X))             -> undefined;
delta_limit(#delta { start_seq_id = StartSeqId }) -> StartSeqId.

%%----------------------------------------------------------------------------
%% Iterator
%%----------------------------------------------------------------------------

ram_ack_iterator(State) ->
    {ack, gb_trees:iterator(State#vqstate.ram_pending_ack)}.

disk_ack_iterator(State) ->
    {ack, gb_trees:iterator(State#vqstate.disk_pending_ack)}.

qi_ack_iterator(State) ->
    {ack, gb_trees:iterator(State#vqstate.qi_pending_ack)}.

msg_iterator(State) -> istate(start, State).

istate(start, State) -> {q4,    State#vqstate.q4,    State};
istate(q4,    State) -> {q3,    State#vqstate.q3,    State};
istate(q3,    State) -> {delta, State#vqstate.delta, State};
istate(delta, State) -> {q2,    State#vqstate.q2,    State};
istate(q2,    State) -> {q1,    State#vqstate.q1,    State};
istate(q1,   _State) -> done.

next({ack, It}, IndexState) ->
    case gb_trees:next(It) of
        none                     -> {empty, IndexState};
        {_SeqId, MsgStatus, It1} -> Next = {ack, It1},
                                    {value, MsgStatus, true, Next, IndexState}
    end;
next(done, IndexState) -> {empty, IndexState};
next({delta, #delta{start_seq_id = SeqId,
                    end_seq_id   = SeqId}, State}, IndexState) ->
    next(istate(delta, State), IndexState);
next({delta, #delta{start_seq_id = SeqId,
                    end_seq_id   = SeqIdEnd} = Delta, State}, IndexState) ->
    SeqIdB = rabbit_queue_index:next_segment_boundary(SeqId),
    SeqId1 = lists:min([SeqIdB, SeqIdEnd]),
    {List, IndexState1} = rabbit_queue_index:read(SeqId, SeqId1, IndexState),
    next({delta, Delta#delta{start_seq_id = SeqId1}, List, State}, IndexState1);
next({delta, Delta, [], State}, IndexState) ->
    next({delta, Delta, State}, IndexState);
next({delta, Delta, [{_, SeqId, _, _, _} = M | Rest], State}, IndexState) ->
    case is_msg_in_pending_acks(SeqId, State) of
        false -> Next = {delta, Delta, Rest, State},
                 {value, beta_msg_status(M), false, Next, IndexState};
        true  -> next({delta, Delta, Rest, State}, IndexState)
    end;
next({Key, Q, State}, IndexState) ->
    case ?QUEUE:out(Q) of
        {empty, _Q}              -> next(istate(Key, State), IndexState);
        {{value, MsgStatus}, QN} -> Next = {Key, QN, State},
                                    {value, MsgStatus, false, Next, IndexState}
    end.

inext(It, {Its, IndexState}) ->
    case next(It, IndexState) of
        {empty, IndexState1} ->
            {Its, IndexState1};
        {value, MsgStatus1, Unacked, It1, IndexState1} ->
            {[{MsgStatus1, Unacked, It1} | Its], IndexState1}
    end.

ifold(_Fun, Acc, [], State) ->
    {Acc, State};
ifold(Fun, Acc, Its, State) ->
    [{MsgStatus, Unacked, It} | Rest] =
        lists:sort(fun ({#msg_status{seq_id = SeqId1}, _, _},
                        {#msg_status{seq_id = SeqId2}, _, _}) ->
                           SeqId1 =< SeqId2
                   end, Its),
    {Msg, State1} = read_msg(MsgStatus, State),
    case Fun(Msg, MsgStatus#msg_status.msg_props, Unacked, Acc) of
        {stop, Acc1} ->
            {Acc1, State};
        {cont, Acc1} ->
            {Its1, IndexState1} = inext(It, {Rest, State1#vqstate.index_state}),
            ifold(Fun, Acc1, Its1, State1#vqstate{index_state = IndexState1})
    end.

%%----------------------------------------------------------------------------
%% Phase changes
%%----------------------------------------------------------------------------

maybe_execute_gc(State = #vqstate {memory_reduction_run_count = MRedRunCount}) ->
    case MRedRunCount >= ?EXPLICIT_GC_RUN_OP_THRESHOLD of
	true -> garbage_collect(),
		 State#vqstate{memory_reduction_run_count =  0};
        false ->    State#vqstate{memory_reduction_run_count =  MRedRunCount + 1}

    end.

reduce_memory_use(State = #vqstate { target_ram_count = infinity }) ->
    State;
reduce_memory_use(State = #vqstate {
                    mode             = default,
                    ram_pending_ack  = RPA,
                    ram_msg_count    = RamMsgCount,
                    target_ram_count = TargetRamCount,
                    io_batch_size    = IoBatchSize,
                    rates            = #rates { in      = AvgIngress,
                                                out     = AvgEgress,
                                                ack_in  = AvgAckIngress,
                                                ack_out = AvgAckEgress } }) ->

    State1 = #vqstate { q2 = Q2, q3 = Q3 } =
        case chunk_size(RamMsgCount + gb_trees:size(RPA), TargetRamCount) of
            0  -> State;
            %% Reduce memory of pending acks and alphas. The order is
            %% determined based on which is growing faster. Whichever
            %% comes second may very well get a quota of 0 if the
            %% first manages to push out the max number of messages.
            S1 -> Funs = case ((AvgAckIngress - AvgAckEgress) >
                                   (AvgIngress - AvgEgress)) of
                             true  -> [fun limit_ram_acks/2,
                                       fun push_alphas_to_betas/2];
                             false -> [fun push_alphas_to_betas/2,
                                       fun limit_ram_acks/2]
                         end,
                  {_, State2} = lists:foldl(fun (ReduceFun, {QuotaN, StateN}) ->
                                                    ReduceFun(QuotaN, StateN)
                                            end, {S1, State}, Funs),
                  State2
        end,

    State3 =
        case chunk_size(?QUEUE:len(Q2) + ?QUEUE:len(Q3),
                        permitted_beta_count(State1)) of
            S2 when S2 >= IoBatchSize ->
                %% There is an implicit, but subtle, upper bound here. We
                %% may shuffle a lot of messages from Q2/3 into delta, but
                %% the number of these that require any disk operation,
                %% namely index writing, i.e. messages that are genuine
                %% betas and not gammas, is bounded by the credit_flow
                %% limiting of the alpha->beta conversion above.
                push_betas_to_deltas(S2, State1);
            _  ->
                State1
        end,
    %% See rabbitmq-server-290 for the reasons behind this GC call.
    garbage_collect(),
    State3;
%% When using lazy queues, there are no alphas, so we don't need to
%% call push_alphas_to_betas/2.
reduce_memory_use(State = #vqstate {
                             mode = lazy,
                             ram_pending_ack  = RPA,
                             ram_msg_count    = RamMsgCount,
                             target_ram_count = TargetRamCount }) ->
    State1 = #vqstate { q3 = Q3 } =
        case chunk_size(RamMsgCount + gb_trees:size(RPA), TargetRamCount) of
            0  -> State;
            S1 -> {_, State2} = limit_ram_acks(S1, State),
                  State2
        end,

    State3 =
        case chunk_size(?QUEUE:len(Q3),
                        permitted_beta_count(State1)) of
            0  ->
                State1;
            S2 ->
                push_betas_to_deltas(S2, State1)
        end,
    maybe_execute_gc(State3).

limit_ram_acks(0, State) ->
    {0, ui(State)};
limit_ram_acks(Quota, State = #vqstate { ram_pending_ack  = RPA,
                                         disk_pending_ack = DPA }) ->
    case gb_trees:is_empty(RPA) of
        true ->
            {Quota, ui(State)};
        false ->
            {SeqId, MsgStatus, RPA1} = gb_trees:take_largest(RPA),
            {MsgStatus1, State1} =
                maybe_prepare_write_to_disk(true, false, MsgStatus, State),
            MsgStatus2 = m(trim_msg_status(MsgStatus1)),
            DPA1 = gb_trees:insert(SeqId, MsgStatus2, DPA),
            limit_ram_acks(Quota - 1,
                           stats({0, 0}, {MsgStatus, MsgStatus2}, 0,
                                 State1 #vqstate { ram_pending_ack  = RPA1,
                                                   disk_pending_ack = DPA1 }))
    end.

permitted_beta_count(#vqstate { len = 0 }) ->
    infinity;
permitted_beta_count(#vqstate { mode             = lazy,
                                target_ram_count = TargetRamCount}) ->
    TargetRamCount;
permitted_beta_count(#vqstate { target_ram_count = 0, q3 = Q3 }) ->
    lists:min([?QUEUE:len(Q3), rabbit_queue_index:next_segment_boundary(0)]);
permitted_beta_count(#vqstate { q1               = Q1,
                                q4               = Q4,
                                target_ram_count = TargetRamCount,
                                len              = Len }) ->
    BetaDelta = Len - ?QUEUE:len(Q1) - ?QUEUE:len(Q4),
    lists:max([rabbit_queue_index:next_segment_boundary(0),
               BetaDelta - ((BetaDelta * BetaDelta) div
                                (BetaDelta + TargetRamCount))]).

chunk_size(Current, Permitted)
  when Permitted =:= infinity orelse Permitted >= Current ->
    0;
chunk_size(Current, Permitted) ->
    Current - Permitted.

fetch_from_q3(State = #vqstate { mode  = default,
                                 q1    = Q1,
                                 q2    = Q2,
                                 delta = #delta { count = DeltaCount },
                                 q3    = Q3,
                                 q4    = Q4 }) ->
    case ?QUEUE:out(Q3) of
        {empty, _Q3} ->
            {empty, State};
        {{value, MsgStatus}, Q3a} ->
            State1 = State #vqstate { q3 = Q3a },
            State2 = case {?QUEUE:is_empty(Q3a), 0 == DeltaCount} of
                         {true, true} ->
                             %% q3 is now empty, it wasn't before;
                             %% delta is still empty. So q2 must be
                             %% empty, and we know q4 is empty
                             %% otherwise we wouldn't be loading from
                             %% q3. As such, we can just set q4 to Q1.
                             true = ?QUEUE:is_empty(Q2), %% ASSERTION
                             true = ?QUEUE:is_empty(Q4), %% ASSERTION
                             State1 #vqstate { q1 = ?QUEUE:new(), q4 = Q1 };
                         {true, false} ->
                             maybe_deltas_to_betas(State1);
                         {false, _} ->
                             %% q3 still isn't empty, we've not
                             %% touched delta, so the invariants
                             %% between q1, q2, delta and q3 are
                             %% maintained
                             State1
                     end,
            {loaded, {MsgStatus, State2}}
    end;
%% lazy queues
fetch_from_q3(State = #vqstate { mode  = lazy,
                                 delta = #delta { count = DeltaCount },
                                 q3    = Q3 }) ->
    case ?QUEUE:out(Q3) of
        {empty, _Q3} when DeltaCount =:= 0 ->
            {empty, State};
        {empty, _Q3} ->
            fetch_from_q3(maybe_deltas_to_betas(State));
        {{value, MsgStatus}, Q3a} ->
            State1 = State #vqstate { q3 = Q3a },
            {loaded, {MsgStatus, State1}}
    end.

maybe_deltas_to_betas(State) ->
    AfterFun = process_delivers_and_acks_fun(deliver_and_ack),
    maybe_deltas_to_betas(AfterFun, State).

maybe_deltas_to_betas(_DelsAndAcksFun,
                      State = #vqstate {delta = ?BLANK_DELTA_PATTERN(X) }) ->
    State;
maybe_deltas_to_betas(DelsAndAcksFun,
                      State = #vqstate {
                        q2                   = Q2,
                        delta                = Delta,
                        q3                   = Q3,
                        index_state          = IndexState,
                        ram_msg_count        = RamMsgCount,
                        ram_bytes            = RamBytes,
                        disk_read_count      = DiskReadCount,
                        delta_transient_bytes = DeltaTransientBytes,
                        transient_threshold  = TransientThreshold }) ->
    #delta { start_seq_id = DeltaSeqId,
             count        = DeltaCount,
             transient    = Transient,
             end_seq_id   = DeltaSeqIdEnd } = Delta,
    DeltaSeqId1 =
        lists:min([rabbit_queue_index:next_segment_boundary(DeltaSeqId),
                   DeltaSeqIdEnd]),
    {List, IndexState1} = rabbit_queue_index:read(DeltaSeqId, DeltaSeqId1,
                                                  IndexState),
    {Q3a, RamCountsInc, RamBytesInc, State1, TransientCount, TransientBytes} =
        betas_from_index_entries(List, TransientThreshold,
                                 DelsAndAcksFun,
                                 State #vqstate { index_state = IndexState1 }),
    State2 = State1 #vqstate { ram_msg_count     = RamMsgCount   + RamCountsInc,
                               ram_bytes         = RamBytes      + RamBytesInc,
                               disk_read_count   = DiskReadCount + RamCountsInc },
    case ?QUEUE:len(Q3a) of
        0 ->
            %% we ignored every message in the segment due to it being
            %% transient and below the threshold
            maybe_deltas_to_betas(
              DelsAndAcksFun,
              State2 #vqstate {
                delta = d(Delta #delta { start_seq_id = DeltaSeqId1 })});
        Q3aLen ->
            Q3b = ?QUEUE:join(Q3, Q3a),
            case DeltaCount - Q3aLen of
                0 ->
                    %% delta is now empty, but it wasn't before, so
                    %% can now join q2 onto q3
                    State2 #vqstate { q2    = ?QUEUE:new(),
                                      delta = ?BLANK_DELTA,
                                      q3    = ?QUEUE:join(Q3b, Q2),
                                      delta_transient_bytes = 0};
                N when N > 0 ->
                    Delta1 = d(#delta { start_seq_id = DeltaSeqId1,
                                        count        = N,
                                        transient    = Transient - TransientCount,
                                        end_seq_id   = DeltaSeqIdEnd }),
                    State2 #vqstate { delta = Delta1,
                                      q3    = Q3b,
                                      delta_transient_bytes = DeltaTransientBytes - TransientBytes }
            end
    end.

push_alphas_to_betas(Quota, State) ->
    {Quota1, State1} =
        push_alphas_to_betas(
          fun ?QUEUE:out/1,
          fun (MsgStatus, Q1a,
               State0 = #vqstate { q3 = Q3, delta = #delta { count = 0,
                                                             transient = 0 } }) ->
                  State0 #vqstate { q1 = Q1a, q3 = ?QUEUE:in(MsgStatus, Q3) };
              (MsgStatus, Q1a, State0 = #vqstate { q2 = Q2 }) ->
                  State0 #vqstate { q1 = Q1a, q2 = ?QUEUE:in(MsgStatus, Q2) }
          end, Quota, State #vqstate.q1, State),
    {Quota2, State2} =
        push_alphas_to_betas(
          fun ?QUEUE:out_r/1,
          fun (MsgStatus, Q4a, State0 = #vqstate { q3 = Q3 }) ->
                  State0 #vqstate { q3 = ?QUEUE:in_r(MsgStatus, Q3), q4 = Q4a }
          end, Quota1, State1 #vqstate.q4, State1),
    {Quota2, State2}.

push_alphas_to_betas(_Generator, _Consumer, Quota, _Q,
                     State = #vqstate { ram_msg_count    = RamMsgCount,
                                        target_ram_count = TargetRamCount })
  when Quota =:= 0 orelse
       TargetRamCount =:= infinity orelse
       TargetRamCount >= RamMsgCount ->
    {Quota, ui(State)};
push_alphas_to_betas(Generator, Consumer, Quota, Q, State) ->
    %% We consume credits from the message_store whenever we need to
    %% persist a message to disk. See:
    %% rabbit_variable_queue:msg_store_write/4. So perhaps the
    %% msg_store is trying to throttle down our queue.
    case credit_flow:blocked() of
        true  -> {Quota, ui(State)};
        false -> case Generator(Q) of
                     {empty, _Q} ->
                         {Quota, ui(State)};
                     {{value, MsgStatus}, Qa} ->
                         {MsgStatus1, State1} =
                             maybe_prepare_write_to_disk(true, false, MsgStatus,
                                                         State),
                         MsgStatus2 = m(trim_msg_status(MsgStatus1)),
                         State2 = stats(
                                    ready0, {MsgStatus, MsgStatus2}, 0, State1),
                         State3 = Consumer(MsgStatus2, Qa, State2),
                         push_alphas_to_betas(Generator, Consumer, Quota - 1,
                                              Qa, State3)
                 end
    end.

push_betas_to_deltas(Quota, State = #vqstate { mode  = default,
                                               q2    = Q2,
                                               delta = Delta,
                                               q3    = Q3}) ->
    PushState = {Quota, Delta, State},
    {Q3a, PushState1} = push_betas_to_deltas(
                          fun ?QUEUE:out_r/1,
                          fun rabbit_queue_index:next_segment_boundary/1,
                          Q3, PushState),
    {Q2a, PushState2} = push_betas_to_deltas(
                          fun ?QUEUE:out/1,
                          fun (Q2MinSeqId) -> Q2MinSeqId end,
                          Q2, PushState1),
    {_, Delta1, State1} = PushState2,
    State1 #vqstate { q2    = Q2a,
                      delta = Delta1,
                      q3    = Q3a };
%% In the case of lazy queues we want to page as many messages as
%% possible from q3.
push_betas_to_deltas(Quota, State = #vqstate { mode  = lazy,
                                               delta = Delta,
                                               q3    = Q3}) ->
    PushState = {Quota, Delta, State},
    {Q3a, PushState1} = push_betas_to_deltas(
                          fun ?QUEUE:out_r/1,
                          fun (Q2MinSeqId) -> Q2MinSeqId end,
                          Q3, PushState),
    {_, Delta1, State1} = PushState1,
    State1 #vqstate { delta = Delta1,
                      q3    = Q3a }.


push_betas_to_deltas(Generator, LimitFun, Q, PushState) ->
    case ?QUEUE:is_empty(Q) of
        true ->
            {Q, PushState};
        false ->
            {value, #msg_status { seq_id = MinSeqId }} = ?QUEUE:peek(Q),
            {value, #msg_status { seq_id = MaxSeqId }} = ?QUEUE:peek_r(Q),
            Limit = LimitFun(MinSeqId),
            case MaxSeqId < Limit of
                true  -> {Q, PushState};
                false -> push_betas_to_deltas1(Generator, Limit, Q, PushState)
            end
    end.

push_betas_to_deltas1(_Generator, _Limit, Q, {0, Delta, State}) ->
    {Q, {0, Delta, ui(State)}};
push_betas_to_deltas1(Generator, Limit, Q, {Quota, Delta, State}) ->
    case Generator(Q) of
        {empty, _Q} ->
            {Q, {Quota, Delta, ui(State)}};
        {{value, #msg_status { seq_id = SeqId }}, _Qa}
          when SeqId < Limit ->
            {Q, {Quota, Delta, ui(State)}};
        {{value, MsgStatus = #msg_status { seq_id = SeqId }}, Qa} ->
            {#msg_status { index_on_disk = true,
                           is_persistent = IsPersistent }, State1} =
                maybe_batch_write_index_to_disk(true, MsgStatus, State),
            State2 = stats(ready0, {MsgStatus, none}, 1, State1),
            Delta1 = expand_delta(SeqId, Delta, IsPersistent),
            push_betas_to_deltas1(Generator, Limit, Qa,
                                  {Quota - 1, Delta1, State2})
    end.

%% Flushes queue index batch caches and updates queue index state.
ui(#vqstate{index_state      = IndexState,
            target_ram_count = TargetRamCount} = State) ->
    IndexState1 = rabbit_queue_index:flush_pre_publish_cache(
                    TargetRamCount, IndexState),
    State#vqstate{index_state = IndexState1}.

%%----------------------------------------------------------------------------
%% Upgrading
%%----------------------------------------------------------------------------

multiple_routing_keys() ->
    transform_storage(
      fun ({basic_message, ExchangeName, Routing_Key, Content,
            MsgId, Persistent}) ->
              {ok, {basic_message, ExchangeName, [Routing_Key], Content,
                    MsgId, Persistent}};
          (_) -> {error, corrupt_message}
      end),
    ok.


%% Assumes message store is not running
transform_storage(TransformFun) ->
    transform_store(?PERSISTENT_MSG_STORE, TransformFun),
    transform_store(?TRANSIENT_MSG_STORE, TransformFun).

transform_store(Store, TransformFun) ->
    rabbit_msg_store:force_recovery(rabbit_mnesia:dir(), Store),
    rabbit_msg_store:transform_dir(rabbit_mnesia:dir(), Store, TransformFun).
