%%% Attempt at writing a simulation that verifies most possible scenarios.
%%% It is based on a central tick server for synchronization, in order to
%%% make this test runnable with concuerror to generate relevant
%%% exhaustive scheduler interleaving tests.
-module(lock_manager_steps).
-compile(export_all).

-define(BUCKETS_SMALL, 2).
-define(BUCKETS_LARGE, 4).
-define(MAXPER, 5).

%% Steps:
%%  - start the lock manager
%%  - start enough workers to fill small buckets many time
%%  - have a central server (the resource) see that it can be filled
%%    at capacity
%%  - send a tick to all workers to start registering in a loop
%%  - the server waits until all entries are full
%%  - the server sends an ack back to the tick server
%%  - start large workers
%%  - tell the server to tell workers to release all locked refs
%%  - wait until all large buckets are taken
%%  - kill the large workers one by one while notifying the central
%%    server they're gone
%%  - release all workers
%%  - fill the small workers again
%%  - check that the total amount of reqs per wave were effectively:
%%    ?BUCKET_SMALL*?MAXPER, ?BUCKETS_LARGE*?MAXPER, ?BUCKETS_SMALL*?MAXPER
%%
%%  maybe not properly tested: registering *while* shrinking down

start() ->
    {ok, Lock} = lock_manager:start_link(?MAXPER),
    MinTot = ?BUCKETS_SMALL*?MAXPER,
    MaxTot = ?BUCKETS_LARGE*?MAXPER,
    Parent = self(),
    Resource = spawn_link(fun() -> resource(Parent) end),
    Resource ! {release_all, MinTot},
    receive
        {Resource, freed} -> ok
    end,
    SmallPids = [spawn_link(fun worker/0) || _ <- lists:seq(1,MinTot*2)],
    [Pid ! {init, Resource, ?MAXPER, ?BUCKETS_SMALL} || Pid <- SmallPids],
    receive
        {Resource, all_locked, MinTot} -> ok
    end,
    BigPids = [spawn_link(fun worker/0) || _ <- lists:seq(1,MaxTot*2)],
    Resource ! {release_all,MaxTot},
    receive
        {Resource, freed} -> ok
    end,
    [Pid ! {init, Resource, ?MAXPER, ?BUCKETS_LARGE} || Pid <- BigPids],
    [Pid ! {init, Resource, ?MAXPER, ?BUCKETS_SMALL} || Pid <- SmallPids],
    receive
        {Resource, all_locked, MaxTot} -> ok
    end,
    Resource ! {release_all,MinTot},
    receive
        {Resource, freed} -> ok
    end,
    [Pid ! {init, Resource, ?MAXPER, ?BUCKETS_SMALL} || Pid <- SmallPids],
    receive
        {Resource, all_locked, MinTot} -> ok
    end.


resource(Pid) -> resource(Pid, 0, []).

resource(Parent, AllLocked, Locks) ->
    receive
        {release_all, NewAll} ->
            [begin
              Pid ! unlock,
              receive
                  {Pid, unlocked} -> ok
              end
             end || Pid <- Locks],
            Parent ! {self(), freed},
            resource(Parent, NewAll, []);
        {Pid, locked} ->
            NewLocks = [Pid | Locks],
            case length(NewLocks) of
                AllLocked -> Parent ! {self(), all_locked, AllLocked};
                N when N < AllLocked -> ok
            end,
            resource(Parent, AllLocked, NewLocks)
    end.

worker() ->
    receive
        {init, Pid, MaxPer, Buckets} ->
            case lock_manager:acquire(key, MaxPer, Buckets) of
                full -> ok;
                acquired ->
                    Pid ! {self(), locked},
                    receive
                        unlock ->
                            ok = lock_manager:release(key, MaxPer, Buckets),
                            Pid ! {self(), unlocked}
                    end
            end
    end,
    worker().

