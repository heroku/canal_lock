-module(lock_manager_prop).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(PROPMOD, proper).
-define(PROP(A), {timeout, 45, ?_assert(?PROPMOD:quickcheck(A(), [100]))}).

proper_test_() ->
    {"Run all property-based tests",
        [?PROP(prop_lock_unlock)]}.

prop_lock_unlock() ->
    ?FORALL({Mod,Num,Keys}, {max_per(), num_resources(), unique_keys()},
        begin
            start(Mod),
            Max = Mod*Num,
            Runs = lists:seq(1,Max),
            Locks = [lock_manager:acquire(Key, Max) || Key <- Keys, _ <- Runs],
            ReLocks1 = [lock_manager:acquire(Key, Max) || Key <- Keys],
            Unlocks = [lock_manager:release(Key, Max) || Key <- Keys, _ <- Runs],
            ReLocks2 = [lock_manager:acquire(Key, Max) || Key <- Keys],
            lists:all(fun(Res) -> Res =:= acquired end, Locks)
            andalso
            lists:all(fun(Res) -> Res =:= full end, ReLocks1)
            andalso
            lists:all(fun(Res) -> Res =:= ok end, Unlocks)
            andalso
            lists:all(fun(Res) -> Res =:= acquired end, ReLocks2)
        end).

downsize_test() ->
    start(5),
    ?assert(lists:all(fun(Res) -> Res =:= acquired end,
                      [lock_manager:acquire(key, 10) || _ <- lists:seq(1,10)])),
    ?assertEqual(full, lock_manager:acquire(key, 10)),
    show_table(),
    %% we downsize!
    ?assertEqual(full, lock_manager:acquire(key, 5)),
    show_table(),
    %% We have 10 keys still active, let's try interleaving them
    ?assertEqual(ok, lock_manager:release(key, 10)), % old leaving
    ?assertEqual(full, lock_manager:acquire(key, 5)), % new trying, tot=9 active
    ?assertEqual(ok, lock_manager:release(key, 10)), % old leaving
    ?assertEqual(full, lock_manager:acquire(key, 5)), % new trying, tot=8 active
    ?assertEqual(ok, lock_manager:release(key, 10)), % old leaving
    ?assertEqual(full, lock_manager:acquire(key, 5)), % new trying, tot=7 active
    ?assertEqual(ok, lock_manager:release(key, 10)), % old leaving
    ?assertEqual(full, lock_manager:acquire(key, 5)), % new trying, tot=6 active
    ?assertEqual(ok, lock_manager:release(key, 10)), % old leaving
    ?assertEqual(full, lock_manager:acquire(key, 5)), % new trying, tot=5 active
    ?assertEqual(ok, lock_manager:release(key, 10)), % old leaving
    show_table(),
    ?assertEqual(acquired, lock_manager:acquire(key, 5)), % new trying, tot=4 active
    show_table().

upsize_release_test() ->
    start(5),
    ?assert(lists:all(fun(Res) -> Res =:= acquired end,
                      [lock_manager:acquire(key, 5) || _ <- lists:seq(1,5)])),
    %% upsize to 10, 6 taken
    ?assertEqual(acquired, lock_manager:acquire(key, 10)),
    show_table(),
    %% releasing when the cap is higher than your max still works
    ?assertEqual(ok, lock_manager:release(key, 5)), % down to 5 taken
    ?assertEqual(full, lock_manager:acquire(key, 5)),
    ?assertEqual(acquired, lock_manager:acquire(key, 10)), % back to 6
    show_table().

show_table() ->
    State = sys:get_state(lock_manager),
    Tab = ets:tab2list(element(2,State)),
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
