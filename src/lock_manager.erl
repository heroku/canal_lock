%% TODO: other undefined behavior: lock at 2max, full at 2max, full at 3max too.
%% That can represent a minimal upwards leak
%% - Can we use a bucketed approach? If you have a per-entry val, you can
%%   represent each as a bucket in a homogenous set - this gives the top-val
%%   leak one chance per bucket, which happens in the manager already, but
%%   loses the leak chance when resizing, though GC may be needed (do it on call
%%   if everything is busy but the limit is down?)
%%   ^-- could this start from a random bucket to have good distribution?
%%   ^-- this raises the chances of the top-boundary issue while reducing
%%       the resize risk
%%   ^-- this handles resizes much nicer
-module(lock_manager).
-behaviour(gen_server).

-export([start_link/1, acquire/2, release/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-record(state, {locks :: ets:tid(),
                refs :: ets:tid(),
                mod :: pos_integer()}).

-define(TABLE, ?MODULE).
-define(MAX_DECR_TRIES, 15).
-define(MAX_DECR_MOD_TRIES, 10).

start_link(MaxMultiplier) ->
    %% The `MaxMultiplier' value can just be the expected `Max', or an
    %% equivalent values in the case you allow, say `X' locks per `N'
    %% instances. In this case, `Max' would be equal to `N * MaxMultiplier',
    %% and `X =:= MaxMultiplier'
    gen_server:start_link({local, ?MODULE}, ?MODULE, MaxMultiplier, []).

acquire(Key, Max) ->
    %% Update the counter and get the value as one single write-only operation,
    %% exploiting the {write_concurrency, true} option set on the table.
    %% If we're at `Max+1' value, we failed to acquire the lock.
    Cap = Max+1,
    try ets:update_counter(?TABLE, Key, {2,1,Cap,Cap}) of
        Cap ->
            full;
        _N ->
            notify_lock(Key),
            acquired
    catch
        error:badarg ->
            %% table is either dead, or element not in there.
            %% We try to insert it -- will error if the table isn't there --
            %% and to acquire the lock at the same time to save an operation
            case ets:insert_new(?TABLE, {Key,1}) of
                true ->
                    notify_lock(Key),
                    acquired;
                false ->
                    %% Someone else beat us to it
                    acquire(Key, Max)
            end
    end.

release(Key, Max) ->
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
    N = ets:update_counter(?TABLE, Key, {2, -1, 0, 0}),
    if N =:= Max ->
            release_loop(Key, Max),
            notify_unlock(Key);
       N < Max ->
            notify_unlock(Key);
       N > Max ->
            %% The value might be greater than 'Max' if the conditions have
            %% changed since the lock was acquired (the max size was shrunk
            %% down). A confusing case, but we have to handle it.
            %% We do not need to lower this value more -- the next client to
            %% try to acquire the lock will apply a ceiling value to it,
            %% and the next proper release may not decrement it fine.
            notify_unlock(Key)
    end.

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
    Refs = ets:new(lock_refs, [set, private]),
    Locks = ets:new(?TABLE, [named_table, public, set, {write_concurrency, true}]),
    {ok, #state{locks=Locks,
                refs=Refs,
                mod=MaxMultiplier}}.

handle_call({unlock, Pid, Key}, _From, S=#state{refs=Tab}) ->
    case ets:lookup(Tab, {Pid, Key}) of
        [{{Pid,Key}, Ref}] ->
            %% Clean up the refs for when the process dies. We
            %% don't clean up from the queue because we don't need to.
            ets:delete(Tab, Ref),
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
            ets:delete(Tab, {Pid,Key}),
            %% Because we can't know for sure if the `Mod' value is the final one
            %% or not, we may have to decrement a bunch of times in a loop, similar
            %% to the external acquisition procedure.
            %% This one risks leaking far more locks than the one that's external,
            %% however, and is only an absolute safeguard in case of failures.
            release_loop_mod(Key, Mod);
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


release_loop(Key, Max) -> release_loop(Key, Max, ?MAX_DECR_TRIES).

release_loop(Key, _Max, 0) ->
    ets:update_counter(?TABLE, Key, {2, -2, 0, 0}),
    notify_unlock(Key);
release_loop(Key, Max, Tries) ->
    N = ets:update_counter(?TABLE, Key, {2, -1, 0, 0}),
    if N =:= Max ->
        release_loop(Key, Max, Tries-1);
       N < Max ->
        ok
    end.

release_loop_mod(Key, Mod) -> release_loop_mod(Key, Mod, ?MAX_DECR_MOD_TRIES).

release_loop_mod(Key, _Mod, 0) ->
    ets:update_counter(?TABLE, Key, {2, -2, 0, 0});
release_loop_mod(Key, Mod, Tries) ->
    N = ets:update_counter(?TABLE, Key, {2, -1, 0, 0}),
    case N rem Mod of
        0 -> % on an edge!
            release_loop_mod(Key, Mod, Tries-1);
        _ -> % anywhere but an edge.
            ok
    end.

