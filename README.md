# Canal Lock Manager

![Rideau Canal Locks](http://i.imgur.com/qOprkk3.jpg)

This is a new lock manager that allow a bit more concurrency for some of our
resource management.

The manager may, in some rare circumstances, allocate for more resources than
what is expected (see [the Algorithm section](#algorithm) for details on this),
which we tend to find preferable to under-allocation in our production systems
where it is being used.

## Do I need this Library? ##

Probably not. It's for a very particular kind of locking that assumes:

- There is no shared memory (only message passing)
- Multiple locks can be acquired for each resource
- The number of resources is variable over time
- The number of resources may both increase and decrease *while*
  other resources and concurrent workers hold locks
- An increase or decrease of resources *should* be reflected in new
  workers trying to acquire them
- There is no time boundary on how long a resource may be in use
- There is no need for queuing (in our case this is due to global properties
  in distributed systems -- order is never guaranteed, therefore queues
  are not required)
- There are thousands and thousands of resources available, and representing
  each of them as a process is not practical nor performant enough.

Under such a scenario using a single counter as a lock, we could get the
following chain of events:


    A -----------> lock [max:3] -------------> ...
    B ------> lock [max:3] --------------------------> ...
    C -----------> lock [max:6] ---------> ...
    D ----------------> lock [max:6] --------------------------> ...
    E -------------> lock [max:3] ---------------------> ...

And from there, it's possible to get a very, very messy interleaving where
counters get nothing less than corrupted. The interleaving above would yield
the following counter values:

    B  A  C  E  D
    1->2->3->4->5

And here, A, B, C and D all got a lock, but E didn't, while the counter got
stuck indicating 5 locks. Just because of this, we now have the potential case
where we are undercounting locks, and enough of these interleavings could leave
us in a state where all locks are seen as used, but none are actually in use. A
perpetual livelock.

*If* this problem happens to you, *then* this library might be for you. See
[Behaviour Under Concurrent Resizes](#behaviour-under-concurrent-resize) for
details on how this library would make the interleaving above work.

## Building

    $ rebar compile

## Running Tests

The tests currently include EUnit tests, and a bunch of property-based tests
that are commented out because they take a long time to run. Uncomment them if
you wish. All of these tests can be run by calling:

    $ rebar get-deps compile eunit --config rebar.tests.config

There is also a [Concuerror](http://concuerror.com/) suite to test all the
potential interleavings of a sequence of locks and resource resizing.

Somehow the test takes very long to finish (it's been run for days without
either finishing nor finding an error), but more work would be required to
make it terminate in a reasonable amount of time in the future.

To run that suite:

    $ rebar compile && concuerror --pa ebin --pa test -f test/canal_lock_steps.erl \
      -m canal_lock_steps -t start --after_timeout 1 --treat_as_normal shutdown

## Usage

The canal lock manager works by using two parameters: buckets and a number of
resources per bucket. For example, assuming we would like 3 connections per
database back-end at most, and that we have 1 backend, the `Buckets` value
would be `1`, and the `MaxPer` would be `3`.

```erlang
1> MaxPer = 3.
3
2> {ok, _Pid} = canal_lock:start_link(MaxPer).
{ok,<0.46.0>}
3> canal_lock:acquire(db, MaxPer, 1).
acquired
4> canal_lock:acquire(db, MaxPer, 1).
acquired
5> canal_lock:acquire(db, MaxPer, 1).
acquired
6> canal_lock:acquire(db, MaxPer, 1).
full
7> canal_lock:acquire(db, MaxPer, 2).
acquired
8> canal_lock:acquire(db, MaxPer, 1).
full
9> canal_lock:release(db, MaxPer, 1).
ok
10> canal_lock:acquire(db, MaxPer, 1).
full
11> canal_lock:release(db, MaxPer, 2).
ok
12> canal_lock:acquire(db, MaxPer, 1).
acquired
13> canal_lock:acquire(db, MaxPer, 1).
full
```

Here's what happens:

1. Variable declaration.
2. Start the lock manager with a `MaxPer` value of 3. The bucket value is
   declared *by the caller* because it's a variable amount, and we prefer to
   have it be local to the caller than global to the node. When new resources
   are added or removed, some in-flight requests won't recognize this.
3. Lock acquired (1/3 of locks used)
4. Lock acquired (2/3 of locks used)
5. Lock acquired (3/3 of locks used)
6. Lock denied (3/3 of locks used)
7. Lock acquired (4/6 of locks used)
8. Lock denied (4/6 of locks used, seen as full given 1-bucketed context)
9. Lock released (3/6 of locks used)
10. Lock denied (3/6 of locks used, seen as full given 1-bucketed context)
11. Lock released (2/6 of locks used)
12. Lock acquired (3/6 of locks used, seen as last available of 3/3)
13. Lock denied (3/6 of locks used, seen as full given 1-bucketed context)

The lock manager does allow more than one lock acquired per process and
will monitor for failures.


## Algorithm

The locking mechanism used is based on the idea of limited resources, of varying
availability. So for example, using back-end servers and access limits, it could
be decided that each back-end can support at most 100 connections, although that
limit is more global than local (i.e. some back-ends can possibly support only
50 connections in practice, but the total limit for the application should still
be higher).

That per-resource limit may be fixed, but the fact that the number of back-ends
may vary is usually not accounted for by most lock management algorithms.

This lock manager works under that idea that blocks of resources available may
vary over the application's life time, and even be doing so in a concurrent
manner (requests made while there were 5 resources will run at the same time as
requests made when 7 were available).

The manager is made of three main moving parts: the caller, the lock manager,
and an ETS table.

The caller is whoever wants to acquire (or release) resources. The manager is in
charge of starting an ETS table, and will track callers in case they fail. The
ETS table will hold the lock state itself.

The lock mechanism itself is based on a series of sub-locks, or buckets. If I
have 3 resources each with a potential 50 acquisitions, the lock for my app will
be of the form

    {{Key,1}, 0..51}
    {{Key,2}, 0..51}
    {{Key,3}, 0..51}

Where 51 is a ceiling value of `$LIMIT+1` meaning "the lock is full".

### Starting the system

The manager must be started first, with a single parameter being the maximal
number of locks per bucket (in the example abov, 50). This value will be used by
the lock manager when decrementing counters.

### Acquiring A Lock

When trying to acquire a lock, the caller will know:

1. The key of the lock
2. The number of acquisitions possible per resources (in the example above, 50)
3. The number of resources available at the time of the call (in the example
   above, 3).

These values must be tracked and reused for releasing the locks.

When acquiring the first lock a call is made with these. Automatically, the
algorithm will begin at bucket `1`, and will try an atomic
`ets:update_counter/3` operation on `{{Key, 1}, Counter}`.

Three results are possible:

1. The bucket doesn't exist (this is the first lock attempted), in which case we
   try to create it and insert a value; if the bucket was concurrently created
   by another request, try again from scratch on that bucket. A value is added
   to the ETS table of the form `{Key, highest}, N}`, tracking the total number
   of buckets made active (this is useful for unlocking)
2. The value returned by `update_counter` is smaller than or equal to the limit,
   in which case the request was acquired. In this case, send an asynchronous
   notification to the lock manager that a lock was acquired on that given Key
   by the current process. The lock manager must set up a monitor on the caller.
3. The value returned is larger than the limit, meaning the lock is full. In
   this case, increment the bucket number by one and try again. If all buckets
   are exhausted, return a value indicating the lock couldn't be acquired.

This makes acquisition simple enough and generally foolproof, assuming the lock
manager started the tables.

#### Manager's job

When a lock notification is received, the manager monitors the calling process
and creates two entries in a private ETS table: `{{Pid, Key}, MonitorRef}` and
`{MonitorRef, Key}`.

This is done asynchronously.

### Releasing a lock

Two types of releases may happen: an orderly release following a 'release' call
by the caller or the caller dying.

#### Manual Call

Releasing a lock is done synchronously, the idea being that if a caller tries to
acquire multiple locks one after the other (sequentially), it should be
rate-limited in its operations, to protect the lock manager.

This could become necessary when there are so many requests and locks that the
manager cannot keep up with the notifications of "I just locked a thing", "I
just released a lock", or "I died, please release my lock". Then there is a
risk of eventually exploding the manager's mailbox and killing the node. A
variant of the algorithm could be made asynchronous, but safety was deemed
important for this initial version.

In any case, the first step is to identify the highest bucket active (done by
looking for `{Key, highest}` in the table). Starting with that bucket, the lock
counter is incremented atomically by -1 (thus reducing the lock count). Four
return values are possible:

1. The number of locks is at below 0. This means the bucket was free already.
   Reincrement the value by one (to bring it to 0, even if multiple unlocks
   happened at once), and try again on a lower bucket. If we were on the lowest
   bucket already, return an error (`out_of_buckets`) as this isn't normal, but
   could happen in specific race conditions with failures before a lock manager
   was notified of unlocks.
2. The number of locks is equal to the limit (50 in the example above). Because
   this is the edge case and that the next lock acquired would reach '51'
   (looking full), decrement the counter again. Now this is where the algorithm
   is fuzzy. Given the right race condition, multiple locks could be attempted
   at once while trying to decrement back to `$LIMIT-1` (49 in the example), so
   this step is done in a loop up to `?MAX_DECR_TRIES`, after which, to avoid
   being livelocked, the lock is decremented by 2. *This may, in rare
   circumstances, end up allocating more resources than expected.* The user of
   the lock manager must be ready to accept that risk.
3. The number of locks remaining is anywhere between 0 and the limit. The lock
   was successfully released.

After each of these possible cases has returned, the unlock is consiered
successful and a call is made to the lock manager, mentioning the key and
process that released it.

Upon reception, the lock manager deletes the two internal entries it had,
unmonitors the process.

#### Caller Dying

If the caller died before sending its notification of release, the lock manager
will receive a `DOWN` message for each individual lock the process had acquired.

On this release, the manager looks up the key associated with the caller by
looking up `MonitorRef` (returning `{Ref, Key}`), and then deletes that entry
from the table, and the `{{Pid, Key}, Ref}` entry.

It then starts an internal release process identical to the one the caller would
have made on its own (this is why the lock manager is configured with a resource
value indicating the max amounts of locks when started.)

It could be interesting to make that loop asynchronous, but benchmarking would
be needed before considering it an optimization.

### Behaviour Under Concurrent Resizes

Given this timeline (the same as earlier):

    A -----------> lock [max:3] -------------> ...
    B ------> lock [max:3] --------------------------> ...
    C -----------> lock [max:6] ---------> ...
    D ----------------> lock [max:6] --------------------------> ...
    E -------------> lock [max:3] ---------------------> ...

The state transtions would now be:

     B    A    C    E    D
    [1]->[2]->[3]->[4]->[4,1]

Whenever the counter for one resource overflows and the call mentions more
resources being expected, a new counter for a new resource is allocated.

To ensure that this always works, the incrementing of counters is always done
left-to-right (oldest counter to newest one), and the decrementing is always
done right-to-left (newest counter to oldest one).

This explains the requirement for always locking from lowest bucket to highest,
and for releasing from highest to lowest.
