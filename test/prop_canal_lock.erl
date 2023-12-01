-module(prop_canal_lock).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

prop_lock_unlock() ->
    ?FORALL({Mod,Num,Keys}, {max_per(), num_resources(), unique_keys()},
        begin
            start(Mod),
            Max = Mod*Num,
            Runs = lists:seq(1,Max),
            Locks = [canal_lock:acquire(Key, Mod, Num) || Key <- Keys, _ <- Runs],
            ReLocks1 = [canal_lock:acquire(Key, Mod, Num) || Key <- Keys],
            Unlocks = [canal_lock:release(Key, Mod, Num) || Key <- Keys, _ <- Runs],
            ReLocks2 = [canal_lock:acquire(Key, Mod, Num) || Key <- Keys],
            lists:all(fun is_acquired/1, Locks)
            andalso
            lists:all(fun is_full/1, ReLocks1)
            andalso
            lists:all(fun is_ok/1, Unlocks)
            andalso
            lists:all(fun is_acquired/1, ReLocks2)
        end).

downsize_release_test() ->
    start(5),
    ?assert(lists:all(fun is_acquired/1,
                      [canal_lock:acquire(key, 5, 2) || _ <- lists:seq(1,10)])),
    ?assertEqual(full, canal_lock:acquire(key, 5, 2)),
    show_table(),
    %% we downsize!
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)),
    show_table(),
    %% We have 10 keys still active, let's try interleaving them
    ?assertEqual(ok, canal_lock:release(key, 5, 2)), % old leaving
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)), % new trying, tot=9 active
    ?assertEqual(ok, canal_lock:release(key, 5, 2)), % old leaving
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)), % new trying, tot=8 active
    ?assertEqual(ok, canal_lock:release(key, 5, 2)), % old leaving
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)), % new trying, tot=7 active
    ?assertEqual(ok, canal_lock:release(key, 5, 2)), % old leaving
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)), % new trying, tot=6 active
    ?assertEqual(ok, canal_lock:release(key, 5, 2)), % old leaving
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)), % new trying, tot=5 active
    ?assertEqual(ok, canal_lock:release(key, 5, 2)), % old leaving
    show_table(),
    ?assertEqual({acquired,5}, canal_lock:acquire(key, 5, 1)), % new trying, tot=4 active
    show_table().

upsize_release_test() ->
    start(5),
    ?assert(lists:all(fun is_acquired/1,
                      [canal_lock:acquire(key, 5, 1) || _ <- lists:seq(1,5)])),
    %% upsize to 10, 6 taken
    show_table(),
    ?assertEqual({acquired, 6}, canal_lock:acquire(key, 5, 2)),
    show_table(),
    %% releasing when the cap is higher than your max still works
    ?assertEqual(ok, canal_lock:release(key, 5, 1)), % down to 5 taken
    show_table(),
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)), % limit enforced by deleting from highest
    show_table(),
    ?assertEqual({acquired, 6}, canal_lock:acquire(key, 5, 2)), % back to 6
    show_table().

release_right_resource_test() ->
    start(3),
    Pid1 = worker(),
    Pid2 = worker(),
    ?assertEqual({acquired,1}, worker_acquire(Pid1, key, 3, 1)),
    ?assertEqual({acquired,2}, worker_acquire(Pid1, key, 3, 1)),
    ?assertEqual({acquired,3}, worker_acquire(Pid2, key, 3, 1)),
    ?assertEqual(full, canal_lock:acquire(key, 3, 1)),
    %% Killing a fake worker that already released its own resource
    %% won't break stuff
    worker_release(Pid2, key, 3, 1),
    worker_die(Pid2),
    %% The lock release is now asynchronous. Prepare for failures through
    %% retries. Only one lock was freed by the process releasing *then* dying
    ?assertEqual({acquired,3}, until_acquired(key, 3, 1, 100)),
    ?assertEqual(timeout, until_acquired(key, 3, 1, 100)),
    worker_die(Pid1),
    %% Two locks should be freed there
    ?assertEqual({acquired,2}, until_acquired(key, 3, 1, 100)),
    ?assertEqual({acquired,3}, until_acquired(key, 3, 1, 100)).

downsize_crash_test() ->
    start(5),
    Pids = [worker() || _ <- lists:seq(1,10)],
    ?assert(lists:all(fun is_acquired/1,
                      [worker_acquire(Pid, key, 5, 2) || Pid <- Pids])),
    ?assertEqual(full, canal_lock:acquire(key, 5, 2)),
    show_table(),
    %% we downsize!
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)),
    show_table(),
    %% We have 10 keys still active, let's try interleaving them
    ?assertEqual(ok, worker_die(lists:nth(1, Pids))), % old leaving
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)), % new trying, tot=9 active
    ?assertEqual(ok, worker_die(lists:nth(2, Pids))), % old leaving
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)), % new trying, tot=8 active
    ?assertEqual(ok, worker_die(lists:nth(3, Pids))), % old leaving
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)), % new trying, tot=7 active
    ?assertEqual(ok, worker_die(lists:nth(4, Pids))), % old leaving
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)), % new trying, tot=6 active
    ?assertEqual(ok, worker_die(lists:nth(5, Pids))), % old leaving
    ?assertEqual(full, canal_lock:acquire(key, 5, 1)), % new trying, tot=5 active
    ?assertEqual(ok, worker_die(lists:nth(6, Pids))), % old leaving
    show_table(),
    ?assertEqual({acquired,5}, canal_lock:acquire(key, 5, 1)), % new trying, tot=4 active
    show_table().

upsize_crash_test() ->
    start(5),
    ?debugVal(upsizecrash),
    Pids = [worker() || _ <- lists:seq(1,5)],
    ?assert(lists:all(fun is_acquired/1,
                      [worker_acquire(Pid, key, 5, 1) || Pid <- Pids])),
    %% upsize to 10, 6 taken
    show_table(),
    ?assertEqual({acquired,6}, canal_lock:acquire(key, 5, 2)),
    show_table(),
    %% releasing when the cap is higher than your max still works
    ?assertEqual(ok, worker_die(lists:nth(1, Pids))), % down to 5 taken
    show_table(),
    ?assertEqual(timeout, until_acquired(key, 5, 1, 100)), % limit enforced by deleting from highest
    show_table(),
    ?assertEqual({acquired,6}, canal_lock:acquire(key, 5, 2)), % back to 6
    show_table().

%ten_k_per_sec_test() ->
%    %% I want 10k locks taken and released in one sec.
%    Per = 100,
%    Buckets = 10,
%    ?debugVal("--"),
%    start(Per), % buckets of Per, we'll have 10 of them
%    L = lists:seq(1,Per*Buckets),
%    T1 = os:timestamp(),
%    Locks = [canal_lock:acquire(key, Per, Buckets) || _ <- L],
%    show_table(),
%    full = canal_lock:acquire(key, Per, Buckets),
%    Unlocks = [canal_lock:release(key, Per, Buckets) || _ <- L],
%    T2 = os:timestamp(),
%    show_table(),
%    Delta = ?debugVal(timer:now_diff(T2,T1)),
%    ?assert(lists:all(fun is_acquired/1, Locks)),
%    ?assert(lists:all(fun is_ok/1, Unlocks)),
%    ?assert(1000000 >= Delta). % 1s in µs
%
%ten_k_per_sec_parallel_test() ->
%    %% I want 10k locks taken and released in one sec.
%    Per = 100,
%    Buckets = 10,
%    ProcCount = 100,
%    Reps = 1000,
%    ?debugVal("||"),
%    start(Per), % buckets of Per, we'll have 10 of them
%    Procs = lists:seq(1,ProcCount),
%    Parent = self(),
%    Fun = fun() ->
%        [case canal_lock:acquire(key, Per, Buckets) of
%                {acquired,_} -> canal_lock:release(key, Per, Buckets);
%                full -> ok
%         end || _ <- lists:seq(1,Reps)],
%        Parent ! done
%    end,
%    T1 = os:timestamp(),
%    [spawn_link(Fun) || _ <- Procs],
%    [receive done -> ok end || _ <- Procs],
%    T2 = os:timestamp(),
%    show_table(),
%    Delta = ?debugVal(timer:now_diff(T2,T1)),
%    ?debugVal({micros_per_lock_unlock, Delta, Delta/(ProcCount*Reps)}),
%    ?assert(1000000 >= Delta). % 1s in µs

show_table() ->
    State = sys:get_state(canal_lock),
    Tab = ets:tab2list(element(2,State)),
%    Tab2 = ets:tab2list(element(3,State)),
%    ?debugVal(Tab2),
    ?debugVal(Tab).

key() -> integer().
keys() -> non_empty(list(key())).
unique_keys() -> ?LET(K, keys(), sets:to_list(sets:from_list(K))).

num_resources() -> ?SUCHTHAT(X, pos_integer(), X > 1 andalso X < 100).
max_per() -> ?SUCHTHAT(X, pos_integer(), X > 1 andalso X < 200).

start(MaxPer) ->
    case whereis(canal_lock) of
        undefined -> ok;
        Pid ->
            process_flag(trap_exit, true),
            exit(Pid, kill),
            receive {'EXIT', Pid, _} -> process_flag(trap_exit, false) end
    end,
    canal_lock:start_link(MaxPer).

worker() ->
    spawn_link(fun F() ->
        receive
            {acquire, From, Key, MaxPer, Num} ->
                From ! {self(), canal_lock:acquire(Key, MaxPer, Num)},
                F();
            {acquire_until, From, Key, MaxPer, Num} ->
                From ! {self(), until_acquired(Key, MaxPer, Num, 100)},
                F();
            {release, From, Key, MaxPer, Num} ->
                From ! {self(), canal_lock:release(Key, MaxPer, Num)},
                F();
            die ->
                exit(asked_for)
        end
    end).

worker_acquire(Pid, Key, MaxPer, Num) ->
    worker_ask(acquire, Pid, Key, MaxPer, Num).

%worker_until_acquired(Pid, Key, MaxPer, Num) ->
%    worker_ask(acquire_until, Pid, Key, MaxPer, Num).

worker_release(Pid, Key, MaxPer, Num) ->
    worker_ask(release, Pid, Key, MaxPer, Num).

worker_ask(Term, Pid, Key, MaxPer, Num) ->
    Pid ! {Term, self(), Key, MaxPer, Num},
    receive
        {Pid, Resp} -> Resp
    end.

worker_die(Pid) ->
    unlink(Pid),
    Ref = erlang:monitor(process, Pid),
    Pid ! die,
    receive
        {'DOWN', Ref, process, Pid, _} -> ok
    end.

until_acquired(_, _, _, Time) when Time =< 0 -> timeout;
until_acquired(Key, Max, Num, Time) ->
    case canal_lock:acquire(Key, Max, Num) of
        {acquired, N} -> {acquired, N};
        full ->
            timer:sleep(5),
            until_acquired(Key,Max,Num,Time-5)
    end.

is_acquired({acquired,_}) -> true;
is_acquired(_) -> false.

is_full(full) -> true;
is_full(_) -> false.

is_ok(ok) -> true;
is_ok(_) -> false.
