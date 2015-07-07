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
[Behaviour Under Concurrent Resizes](#behaviour-under-concurrent-resizes) for
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
{acquired,1}
4> canal_lock:acquire(db, MaxPer, 1).
{acquired,2}
5> canal_lock:acquire(db, MaxPer, 1).
{acquired,3}
6> canal_lock:acquire(db, MaxPer, 1).
full
7> canal_lock:acquire(db, MaxPer, 2).
{acquired,4}
8> canal_lock:acquire(db, MaxPer, 1).
full
9> canal_lock:release(db, MaxPer, 1).
ok
10> canal_lock:acquire(db, MaxPer, 1).
full
11> canal_lock:release(db, MaxPer, 2).
ok
12> canal_lock:acquire(db, MaxPer, 1).
{acquired,3}
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


## Algorithm (conceptual explanation)

### Atomic Counters ###

It's a well-known secret in the Erlang community that ETS tables are an easy way to optimize your code. They provide destructive updates in a well-isolated context, concurrency primitives other than a mailbox, and decent concurrent access.

ETS tables are basically an in-memory key-value store living within any Erlang VM, implemented in C. They have automated read and write lock management, but no transactions. They provide optimized modes for read-only or write-only sequences of operations, easily scaling to many cores. They also offer atomic access to counters, with the following properties:

- The counters are modified by a given increment (`0`, `+N` or `-N`)
- The counters allow increments with boundary values (not smaller or larger than `X`)
- The counters can be atomically set back to a custom value if a boundary is hit.
- The counters return their value after the increment operation atomically while still in a write context (this mean we can read counters atomically by incrementing them by 0, without forcing a read lock!)

With these primitives only, it becomes possible to write a user-land mutex. So if I want to have a mutex allowing 5 locks to be acquired, I start with a counter set to 0. I can then do as follows:

- Update the counter by `+1` with a limit of `6`. The value returned is `1`, so I've acquired my lock.
- Update the counter similarly 4 more times, such that the last value returned is `5`, and all locks are acquired.
- Whenever the counter reaches `6`, it is full and my request has failed.

To release a lock, just decrement the counter with a floor value set to `0`. If I have lock `1` and decrement by `1`, the counter is back at 0 and we're fine. Now there's a fun problem here: Because our atomicicity constraint limits us to writing before we read anything, and because between those two writes anyone else can touch the value, there's no good way to react when we decrement the counter and see the value `5` being returned. This means we just decremented a null lock, from 6 to 5, and the next person to lock will hit 6 again!

There's a conundrum for you. The correct way to fix this one given our constraints is that whenever we hit `5`, we try to unlock a second time (so that `6 --> 4`, freeing the lock we had acquired properly). But it's possible that in between these two operations, someone else attempts to acquire the lock! Whoops.

We enter a potential infinite livelock where the operation order is:

- A tries to unlock
- B tries to lock
- A tries to unlock
- B tries to lock
- ...

If any unlock sequence can manage to do its thing twice in a row, we'll be fine, but there's no guarantee this will ever happen!

This leaves us oscillating between 5 and 6 nearly indefinitely. So what we do is add a *liveliness* constraint to the problem. We say that when we try the above more than say, 10 times unsuccessfully, we say "forget it" and decrement by `2`. This has the nice effect of never livelocking, but the nefarious effect of sometimes leaking a request:

- A tries to unlock
- B tries to lock
- A tries to unlock
- B tries to lock
- ...
- A tries to unlock
- A forces a double-unlock
- B succeeds in locking
- C succeeds ing locking

The compromise being that we're happier with a few rare request leaks than a few rare livelocks[4]

What we built on these foundations was a simple prototype that showed very good performance, entirely satisfactory. But this would have been too easy if it had worked right out of the box.
### My locks keep being resized

One of the very tricky aspects of locking dynos is that numbers of dynos isn't fixed. This means that at any given time, the lock itself may need to be made larger or truncated!

To see how this happens, let's imagine the following scenario, where 6 requests in their own processes (A, B, C, D, and E, started in that order) try to lock the same application. The router allows only 3 locks per dyno, and the app has 1 dyno.

At the time A and B were started, `3` locks at most were allowed. Concurrently, the user boots a dyno, so by the time C and D get started, 6 locks were made available in total. Then the user scales down, and only 3 locks are available again.

If A, and B can finish before the scaling event happens, and that C and D are started after scaling up and finish before we scale down, and that E is starting after the scaling down is complete, we're fine:

    A ---> lock [max:3] ----> unlock
    B -----> lock [max:3] ------> unlock
    C ---------------------> lock [max: 6] -----> unlock
    D -----------------------> lock [max: 6] -----> unlock
    E ---------------------------------------> lock [max: 3] -----> unlock

This gives us an interleaving where the following locks are owned or active at each request:

    A: 1
    B: 2
    C: 3
    D: 4
    E: 3

Which works fine. But if we imagine a more compact timeline, we could very well end up with:

    A -----------> lock [max:3] -------------> ...
    B ------> lock [max:3] --------------------------> ...
    C -----------> lock [max:6] ---------> ...
    D ----------------> lock [max:6] --------------------------> ...
    E -------------> lock [max:3] ---------------------> ...

For the following lock values:

    A: 2
    B: 1
    C: 3
    D: 5
    E: 4 (blocked)

And all of a sudden, we're stuck with 5 locks, with only 4 of them actually acquired! Instead of leaking requests through, we're leaking locks through. This means that under a system with these properties, individual apps would eventually become unable to acquire any resource! The problem is that a single counter like that is not amenable to being resized safely, because we use an overflow value (`Limit+1`) to know when it's full. D'oh!

### Enter Canal Lock

Canal lock is the next level to make this work. The gotcha at the core of canal lock is that there is no reason for us to have only one counter per application if the counter value is per-dyno. We can just go back to a per-dyno counter (without a queue!) and iterate through them. So rather than having 3 locks available and then 6 within the same counter, we start a second counter for the app. So for one dyno I have a single `[3]` counter. For two dynos, I have `[3,3]`, for three dynos, `[3,3,3]`, and so on.

What we do then is to try to lock each single counter in order, starting from the first one:

    [0,0,0] 0 locks
    [1,0,0] 1 lock
    [2,0,0] 2 locks
    [3,0,0] 3 locks
    [4,0,0] (try again)
    [4,1,0] 4 locks
    [4,2,0] 5 locks
    [4,3,0] 6 locks
    [4,4,0] (try again)
    [4,4,1] 7 locks
    ...

And so on. Each of these locks is like an individual one.

To decrement them, we do the opposite:

    [4,4,1]  7 locks
    [4,4,0]  6 locks
    [4,3,-1] (put the value back at 0)
    [4,3,0]  (unlock again)
    [4,2,0]  5 locks
    [4,1,0]  4 locks
    [4,0,0]  3 locks
    [3,-1,0] (put the value back at 0)
    [3,0,0]  (unlock again)
    [2,0,0]  2 locks
    [1,0,0]  1 lock
    [0,0,0]  0 locks

So rather than having a `O(1)` algorithm, we end up with `O(n)` where `n` is the number of dynos, but unless someone has millions of dynos (which just doesn't happen), the lock mechanism should be very fast.

For the earlier case of A, B, C, D, and E with maximal interleaving, we now see:

    A: 2
    B: 1
    C: 3
    D: 4,1
    E: 4 (blocked)

What's interesting about this one is that we properly respect the number of locks registered to the number of locks acquired, and that even though locks are acquired in any order, they get accepted or denied based on how many resources *each request* thinks it should respect. This means that no matter what the interleaving is, requests spawned at a time where many dynos were available will be able to act as such, and peacefully coexist with requests created when fewer dynos existed. This means that we maintain both the global lock constraints while maintaining each requests' own local view of what they should be able to use.

## Algorithm (in practice)

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
