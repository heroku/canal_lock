%% TODO: other undefined behavior: lock at 2max, full at 2max, full at 3max too.
%% That can represent a minimal upwards leak
%%
%%% N.B. All the buckets are tried sequentially in order for us to minimize the
%%% amount of work needed to decrement without error.
-module(lock_manager).
-behaviour(gen_server).

-export([start_link/1, acquire/3, release/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-record(state, {locks :: ets:tid(),
                refs :: ets:tid(),
                mod :: pos_integer()}).

-define(TABLE, ?MODULE).
-define(MAX_DECR_TRIES, 15).

start_link(MaxMultiplier) ->
    %% The `MaxMultiplier' value can just be the expected `Max', or an
    %% equivalent values in the case you allow, say `X' locks per `N'
    %% instances. In this case, `Max' would be equal to `N * MaxMultiplier',
    %% and `X =:= MaxMultiplier'
    gen_server:start_link({local, ?MODULE}, ?MODULE, MaxMultiplier, []).

acquire(Key, MaxPer, NumResources) ->
    acquire(Key, MaxPer, NumResources, 1).

acquire(Key, MaxPer, NumResources, Bucket) ->
    %% Update the counter and get the value as one single write-only operation,
    %% exploiting the {write_concurrency, true} option set on the table.
    %% If we're at `Max+1' value, we failed to acquire the lock.
    Cap = MaxPer+1,
    try ets:update_counter(?TABLE, {Key,Bucket}, {2,1,Cap,Cap}) of
        Cap when NumResources =:= Bucket ->
            full;
        Cap ->
            acquire(Key, MaxPer, NumResources, Bucket+1);
        _N ->
            notify_lock(Key),
            acquired
    catch
        error:badarg ->
            %% table is either dead, or element not in there.
            %% We try to insert it -- will error if the table isn't there --
            %% and to acquire the lock at the same time to save an operation
            case ets:insert_new(?TABLE, {{Key,Bucket},1}) of
                true ->
                    case Bucket of
                       1 -> ets:insert(?TABLE, {{Key,highest},1});
                       _ -> ets:update_counter(?TABLE, {Key,highest}, {2,1})
                    end,
                    notify_lock(Key),
                    acquired;
                false ->
                    %% Someone else beat us to it
                    acquire(Key, MaxPer, NumResources, Bucket)
            end
    end.

release(Key, MaxPer, NumResources) ->
    %% TODO: See if this logic needs to be moved inside the lock manager or
    %%       if it can stay out.
    %%
    %% We need to know the max value, because on a decrement, there's some
    %% fancy logic that needs to happen where we double-decrement to avoid
    %% being stock in a full lock forever.
    %%
    %% For example, a 3-lock would have these possible values:
    %% - 0 (free, never seen except on a release)
    %% - 1 (1 lock, seen on first acquire)
    %% - 2 (2 locks, seen on second acquire)
    %% - 3 (3 locks, seen on third acquire)
    %% - 4 (full, seen on all denied entries)
    %%
    %% Because we might be at `4' as a value, we will need to double-decrement
    %% it to `2', so that the person acquiring the third lock can indeed grab
    %% it. This mechanism, however, given the right concurrency conditions
    %% with sets of nodes fighting for it and us only being able to decrement
    %% it as one atomic operation, forces us to leak locks from time to time.
    %%
    %% The lock can either be leaked in the form of always decrementing by two
    %% and then incrementing by one if the atomic result `=< Max-1', or by
    %% decrementing by 1, seeing if the result is `Max', then decrementing
    %% again until we get to `Max-1'. The latter solution would work, but
    %% to ensure it finishes, it will need to give up and decrement by two at
    %% some point (where it could then reincrement by one if it sees it's too
    %% low, but that might be too little too late).
    %%
    %% Because we take a bucketed approach, the same thing may happen from the
    %% floor position: if you decrement an empty bucket, you'll get a
    %% value < 0, then need to increment it back, then try the next bucket.
    %% If another app came in the mean time and grabbed a lock while the counter
    %% was below 0, it's fine, as one of the reincrements we will eventually
    %% account for it.
    %%
    case release_loop(Key, MaxPer) of
        ok -> ok;
        {error, out_of_buckets} -> warn_buckets(Key, NumResources)
    end,
    notify_unlock(Key).

notify_lock(Key) ->
    gen_server:cast(?MODULE, {lock, self(), Key}).

notify_unlock(Key) ->
    %% This call needs to be synchronous to avoid having a process locking
    %% itself out of its locks by locking faster than unlocking went!
    gen_server:call(?MODULE, {unlock, self(), Key}).

init(MaxMultiplier) ->
    %% We start the refs table before the locks tablel to minimize the amount
    %% of time we may be without a registered process, which would lead to
    %% a sequence of registers, followed by crashes when trying to notify this
    %% named server without a name. The general result would be leaked locks.
    %%
    %% The Refs table holds its own lookup table: `{Ref, Key}' for crashes, and
    %% `{{Pid,Key},Ref}' for proper releases.
    Refs = ets:new(lock_refs, [bag, public]),
    Locks = ets:new(?TABLE, [named_table, public, set, {write_concurrency, true}]),
    {ok, #state{locks=Locks,
                refs=Refs,
                mod=MaxMultiplier}}.

handle_call({unlock, Pid, Key}, _From, S=#state{refs=Tab}) ->
    case ets:lookup(Tab, {Pid, Key}) of
        [{{Pid,Key}, Ref}|_] -> % pick any ref
            %% Clean up the refs for when the process dies. We
            %% don't clean up from the queue because we don't need to.
            ets:delete(Tab, Ref),
            ets:delete_object(Tab, {{Pid,Key},Ref}),
            erlang:demonitor(Ref),
            {reply, ok, S};
        [] -> %% This is bad
            error_logger:error_msg("mod=lock_manager at=unlock "
                                   "error=unexpected_unlock key=~p~n",
                                   [Key]),
            {reply, ok, S}
    end;
handle_call(Call, _From, S=#state{}) ->
    error_logger:warning_msg("mod=lock_manager at=handle_call "
                             "warning=unexpected_msg message=~p~n",
                             [Call]),
    {noreply, S}.

handle_cast({lock, Pid, Key}, S=#state{refs=Tab}) ->
    Ref = erlang:monitor(process, Pid),
    ets:insert(Tab, [{{Pid,Key},Ref}, {Ref,Key}]),
    {noreply, S};
handle_cast(Cast, S=#state{}) ->
    error_logger:warning_msg("mod=lock_manager at=handle_cast "
                             "warning=unexpected_msg message=~p~n",
                             [Cast]),
    {noreply, S}.

handle_info({'DOWN', Ref, process, Pid, _Reason}, S=#state{refs=Tab, mod=Mod}) ->
    case ets:lookup(Tab, Ref) of
        [{Ref,Key}] ->
            ets:delete(Tab, Ref),
            ets:delete_object(Tab, {{Pid,Key},Ref}),
            %% Because we can't know for sure if the `Mod' value is the final one
            %% or not, we may have to decrement a bunch of times in a loop, similar
            %% to the external acquisition procedure.
            case release_loop(Key, Mod) of
                ok -> ok;
                {error, out_of_buckets} -> warn_buckets(Key, find_highest_bucket(Key))
            end;
        [] ->
            %% we already handled an unlock there, and the process must
            %% have died before we stopped monitoring. Alternatively, this
            %% is a made-up message, but we can't account for that.
            ok
    end,
    {noreply, S};
handle_info(Info, S=#state{}) ->
    error_logger:warning_msg("mod=lock_manager at=handle_info "
                             "warning=unexpected_msg message=~p~n",
                             [Info]),
    {noreply, S}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.


release_loop(Key, MaxPer) ->
    HighestBucket = find_highest_bucket(Key),
    release_loop(Key, MaxPer, HighestBucket, HighestBucket).

release_loop(Key, MaxPer, NumResources, Bucket) ->
    %% This bucket should exist, otherwise we're leaking connections
    %% anyway and will need to think hard about solving it.
    N = ets:update_counter(?TABLE, {Key,Bucket}, {2, -1}),
    if N < MaxPer, N >= 0 ->
           ok;
       N =:= MaxPer ->
           release_loop_inner({Key,Bucket}, MaxPer),
           ok;
       N < 0, Bucket =:= 1 ->
           %% We decremented too much, undo this. But because
           %% this is the last bucket, this is all we could do.
           %% Somehow, something is wrong and we're leaking a lock.
           %% We have to give up though.
           ets:update_counter(?TABLE, {Key,Bucket}, {2, 1}),
           {error, out_of_buckets};
       N < 0 ->
           %% We decremented too much -- this bucket was empty already.
           %% Undo this and try the next one.
           ets:update_counter(?TABLE, {Key,Bucket}, {2, 1}),
           release_loop(Key, MaxPer, NumResources, Bucket-1)
    end.

release_loop_inner(Key, Max) -> release_loop_inner(Key, Max, ?MAX_DECR_TRIES).

release_loop_inner(Key, _Max, 0) ->
    ets:update_counter(?TABLE, Key, {2, -2, 0, 0});
release_loop_inner(Key, Max, Tries) ->
    N = ets:update_counter(?TABLE, Key, {2, -1, 0, 0}),
    if N =:= Max ->
        release_loop_inner(Key, Max, Tries-1);
       N < Max ->
        ok
    end.

find_highest_bucket(Key) ->
    ets:update_counter(?TABLE, {Key,highest}, {2,0}).

warn_buckets(Key, Bucket) ->
    error_logger:warning_msg("mod=lock_manager at=release_loop_mod "
                             "warning=out_of_buckets key=~p bucket=~p~n",
                             [Key,Bucket]).
