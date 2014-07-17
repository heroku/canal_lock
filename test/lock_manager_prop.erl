-module(lock_manager_prop).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

%-define(PROPMOD, proper).
%-define(PROP(A), {timeout, 60, ?_assert(?PROPMOD:quickcheck(A(), [100]))}).
%
%proper_test_() ->
%    {"Run all property-based tests",
%        [?PROP(prop_lock_unlock)]}.
%
%prop_lock_unlock() ->
%    ?FORALL({Mod,Num,Keys}, {max_per(), num_resources(), unique_keys()},
%        begin
%            start(Mod),
%            Max = Mod*Num,
%            Runs = lists:seq(1,Max),
%            Locks = [lock_manager:acquire(Key, Mod, Num) || Key <- Keys, _ <- Runs],
%            ReLocks1 = [lock_manager:acquire(Key, Mod, Num) || Key <- Keys],
%            Unlocks = [lock_manager:release(Key, Mod, Num) || Key <- Keys, _ <- Runs],
%            ReLocks2 = [lock_manager:acquire(Key, Mod, Num) || Key <- Keys],
%            lists:all(fun(Res) -> Res =:= acquired end, Locks)
%            andalso
%            lists:all(fun(Res) -> Res =:= full end, ReLocks1)
%            andalso
%            lists:all(fun(Res) -> Res =:= ok end, Unlocks)
%            andalso
%            lists:all(fun(Res) -> Res =:= acquired end, ReLocks2)
%        end).

%% TODO: same test through crashes only
downsize_test() ->
    start(5),
    ?assert(lists:all(fun(Res) -> Res =:= acquired end,
                      [lock_manager:acquire(key, 5, 2) || _ <- lists:seq(1,10)])),
    ?assertEqual(full, lock_manager:acquire(key, 5, 2)),
    show_table(),
    %% we downsize!
    ?assertEqual(full, lock_manager:acquire(key, 5, 1)),
    show_table(),
    %% We have 10 keys still active, let's try interleaving them
    ?assertEqual(ok, lock_manager:release(key, 5, 2)), % old leaving
    ?assertEqual(full, lock_manager:acquire(key, 5, 1)), % new trying, tot=9 active
    ?assertEqual(ok, lock_manager:release(key, 5, 2)), % old leaving
    ?assertEqual(full, lock_manager:acquire(key, 5, 1)), % new trying, tot=8 active
    ?assertEqual(ok, lock_manager:release(key, 5, 2)), % old leaving
    ?assertEqual(full, lock_manager:acquire(key, 5, 1)), % new trying, tot=7 active
    ?assertEqual(ok, lock_manager:release(key, 5, 2)), % old leaving
    ?assertEqual(full, lock_manager:acquire(key, 5, 1)), % new trying, tot=6 active
    ?assertEqual(ok, lock_manager:release(key, 5, 2)), % old leaving
    ?assertEqual(full, lock_manager:acquire(key, 5, 1)), % new trying, tot=5 active
    ?assertEqual(ok, lock_manager:release(key, 5, 2)), % old leaving
    show_table(),
    ?assertEqual(acquired, lock_manager:acquire(key, 5, 1)), % new trying, tot=4 active
    show_table().

%% TODO: same test through crashes only
upsize_release_test() ->
    start(5),
    ?assert(lists:all(fun(Res) -> Res =:= acquired end,
                      [lock_manager:acquire(key, 5, 1) || _ <- lists:seq(1,5)])),
    %% upsize to 10, 6 taken
    show_table(),
    ?assertEqual(acquired, lock_manager:acquire(key, 5, 2)),
    show_table(),
    %% releasing when the cap is higher than your max still works
    ?assertEqual(ok, lock_manager:release(key, 5, 1)), % down to 5 taken
    show_table(),
    ?assertEqual(acquired, lock_manager:acquire(key, 5, 1)), % free from the first bucket
    show_table(),
    ?assertEqual(acquired, lock_manager:acquire(key, 5, 2)), % back to 7, with overflow
    show_table().

ten_k_per_sec_test() ->
    %% I want 10k locks taken and released in one sec.
    Per = 100,
    Buckets = 10,
    ?debugVal("--"),
    start(Per), % buckets of Per, we'll have 10 of them
    L = lists:seq(1,Per*Buckets),
    T1 = os:timestamp(),
    Locks = [lock_manager:acquire(key, Per, Buckets) || _ <- L],
    show_table(),
    full = lock_manager:acquire(key, Per, Buckets),
    Unlocks = [lock_manager:release(key, Per, Buckets) || _ <- L],
    T2 = os:timestamp(),
    show_table(),
    Delta = ?debugVal(timer:now_diff(T2,T1)),
    ?assert(lists:all(fun(Res) -> Res =:= acquired end, Locks)),
    ?assert(lists:all(fun(Res) -> Res =:= ok end, Unlocks)),
    ?assert(1000000 >= Delta). % 1s in µs

ten_k_per_sec_parallel_test() ->
    %% I want 10k locks taken and released in one sec.
    Per = 100,
    Buckets = 10,
    ProcCount = 100,
    Reps = 1000,
    ?debugVal("||"),
    start(Per), % buckets of Per, we'll have 10 of them
    Procs = lists:seq(1,ProcCount),
    Parent = self(),
    Fun = fun() ->
        [case lock_manager:acquire(key, Per, Buckets) of
                acquired -> lock_manager:release(key, Per, Buckets);
                full -> ok
         end || _ <- lists:seq(1,Reps)],
        Parent ! done
    end,
    T1 = os:timestamp(),
    [spawn_link(Fun) || _ <- Procs],
    [receive done -> ok end || _ <- Procs],
    T2 = os:timestamp(),
    show_table(),
    Delta = ?debugVal(timer:now_diff(T2,T1)),
    ?debugVal({micros_per_lock_unlock, Delta, Delta/(ProcCount*Reps)}),
    ?assert(1000000 >= Delta). % 1s in µs

show_table() ->
    State = sys:get_state(lock_manager),
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
    case whereis(lock_manager) of
        undefined -> ok;
        Pid ->
            process_flag(trap_exit, true),
            exit(Pid, kill),
            receive {'EXIT', Pid, _} -> process_flag(trap_exit, false) end
    end,
    lock_manager:start_link(MaxPer).
