%%% Attempt at writing a simulation that verifies most possible scenarios.
%%% It is based on a central tick server for synchronization, in order to
%%% make this test runnable with concuerror to generate relevant
%%% exhaustive scheduler interleaving tests.
%%%
%%% Run with Concuerror as:
%%%
%%% rebar compile && concuerror --pa ebin --pa test -f test/canal_lock_steps.erl \
%%% -m canal_lock_steps -t start --after_timeout 1 --treat_as_normal shutdown
%%%
%%% The last two options are required to make sure that Concuerror doesn't
%%% explore (and voluntarily trigger) timeouts, not required for this test, and
%%% that the 'shutdown' ending of the lock manager isn't considered an error --
%%% it is only triggered manually at the end of each run.
-module(canal_lock_steps).
-compile(export_all).

-define(BUCKETS_SMALL, 2).
-define(BUCKETS_LARGE, 3).
-define(MAXPER, 2).

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
    {ok, _Pid} = canal_lock:start_link(?MAXPER),
    MinTot = ?BUCKETS_SMALL*?MAXPER,
    MaxTot = ?BUCKETS_LARGE*?MAXPER,
    Parent = self(),
    Resource = spawn_link(fun() -> resource(Parent) end),
    Resource ! {release_all, MinTot},
    receive
        {Resource, freed} -> ok
    end,
    SmallPids = [spawn_link(fun worker/0) || _ <- lists:seq(1,MinTot+2)],
    [Pid ! {init, Resource, ?MAXPER, ?BUCKETS_SMALL} || Pid <- SmallPids],
    receive
        %{Resource, all_locked, MinTot} -> sync_all(SmallPids)
        {Resource, all_locked, MinTot} -> ok
    end,
    BigPids = [spawn_link(fun worker/0) || _ <- lists:seq(1,MaxTot+2)],
    Resource ! {release_all,MaxTot},
    receive
        {Resource, freed} -> sync_all(SmallPids)
    end,
    [Pid ! {init, Resource, ?MAXPER, ?BUCKETS_LARGE} || Pid <- BigPids],
    [Pid ! {init, Resource, ?MAXPER, ?BUCKETS_SMALL} || Pid <- SmallPids],
    receive
        %{Resource, all_locked, MaxTot} -> %sync_all(SmallPids++BigPids)
        {Resource, all_locked, MaxTot} -> ok
    end,
    Resource ! {release_all,MinTot},
    receive
        {Resource, freed} -> sync_all(SmallPids++BigPids)
    end,
    [Pid ! {init, Resource, ?MAXPER, ?BUCKETS_SMALL} || Pid <- SmallPids],
    receive
        %{Resource, all_locked, MinTot} -> sync_all(SmallPids++BigPids)
        {Resource, all_locked, MinTot} -> ok
    end,
    %% release workers
    Resource ! {release_all,MaxTot},
    receive
        {Resource, freed} -> sync_all(SmallPids++BigPids)
    end,
    cause_death(Resource),
    [cause_death(Pid) || Pid <- SmallPids++BigPids],
    canal_lock:stop().


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
            %% This case crashes if more locks are acquired than available
            case length(NewLocks) of
                AllLocked -> Parent ! {self(), all_locked, AllLocked};
                N when N < AllLocked -> ok
            end,
            resource(Parent, AllLocked, NewLocks);
        {fin, Pid} ->
            Pid ! {self(), fin}
    end.

worker() ->
    receive
        {init, Pid, MaxPer, Buckets} ->
            case canal_lock:acquire(key, MaxPer, Buckets) of
                full -> worker();
                acquired ->
                    Pid ! {self(), locked},
                    locked_worker(Pid, MaxPer, Buckets)
            end;
        {sync, Pid} ->
            Pid ! {self(), sync},
            worker();
        {fin, Pid} ->
            Pid ! {self(), fin}
    end.

locked_worker(Pid, MaxPer, Buckets) ->
    receive
        {sync, Caller} ->
            Caller ! {self(), sync},
            locked_worker(Pid, MaxPer, Buckets);
        unlock ->
            ok = canal_lock:release(key, MaxPer, Buckets),
            Pid ! {self(), unlocked},
            worker();
        {fin, Caller} ->
            Caller ! {self(), fin}
    end.

sync_all([]) -> ok;
sync_all([Pid|Pids]) ->
    Pid ! {sync, self()},
    receive
        {Pid, sync} -> sync_all(Pids)
    end.

cause_death(Pid) ->
    Pid ! {fin, self()},
    receive
        {Pid, fin} -> ok
    end.
