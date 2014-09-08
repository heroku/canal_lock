# ??? Locking Manager

TODO: fill this in, pick a name

## Picking name

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
rate-limited in its operations, to protect the lock manager. I do not believe it
is necessary, however.

The first step is to identify the highest bucket active (done by looking for
`{Key, highest}` in the table). Starting with that bucket, the lock counter is
incremented atomically by -1 (thus reducing the lock count). Four return values
are possible:

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
have made on its own.

It could be interesting to make that loop asynchronous, but benchmarking would
be needed before considering it an optimization.

### Behaviour Under Concurrent Resizes

Given this timeline:

    A -----------> lock [max:3] -------------> ...
    B ------> lock [max:3] --------------------------> ...
    C -----------> lock [max:6] ---------> ...
    D ----------------> lock [max:6] --------------------------> ...
    E -------------> lock [max:3] ---------------------> ...

The state transtions would be:

     B    A    C    E    D
    [1]->[2]->[3]->[4]->[4,1]

Whenever the counter for one resource overflows and the call mentions more
resources being expected, a new counter for a new resource is allocated.

To ensure that this always works, the incrementing of counters is always done
left-to-right (oldest counter to newest one), and the decrementing is always
done right-to-left (newest counter to oldest one).

This explains the requirement for always locking from lowest bucket to highest,
and for releasing from highest to lowest.
