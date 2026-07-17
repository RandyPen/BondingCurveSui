/// Token-page discussion. A comment is ONLY an event — nothing is stored:
/// no comment object, no pool field, no counter, no registry.
///
/// `post` borrows the pool IMMUTABLY, so a comment never write-conflicts with
/// a trade on that pool's shared object. That upholds the property `pool`'s
/// module doc already claims (trades never contend with anything but trades),
/// and the borrow checker enforces it — there is nothing to test.
///
/// The comment id is `ctx.fresh_object_address()`: a globally unique address
/// that no object occupies and that, per the framework, can never collide with
/// a user's address. It needs no shared state, and N comments in one PTB get N
/// distinct ids. It is UNIQUE, NOT RANDOM — it derives from the transaction
/// digest, which a sender knows before submitting. Never use it as randomness.
///
/// What this module CANNOT verify: that `reply_to` names a real comment, or one
/// on this pool. There is no comment state to check against, so `reply_to` is
/// recorded verbatim as an unverified caller claim. Consumers MUST resolve every
/// edge against their own ingested set and refuse the ones that do not hold —
/// see `skills/launchpad-data/SKILL.md`. Do not "fix" this by adding state
/// without re-reading that contract first.
module bondingcurvesui::comment;

use std::string::String;
use sui::event;

use bondingcurvesui::config::LaunchpadConfig;
use bondingcurvesui::pool::Pool;

// === Errors ===

/// Comment body is empty.
const EEmptyComment: u64 = 1;
/// Comment body exceeds `MAX_COMMENT_LEN`.
const ECommentTooLong: u64 = 2;

// === Constants ===

/// Maximum comment body, in BYTES — `String::length` is a byte count, so this
/// is 15000 ASCII characters but exactly 5000 CJK ones (3 bytes each).
///
/// The hard ceiling is 16382, not the event size limit (`max_event_emit_size`,
/// 256000) but the PURE ARGUMENT limit (`max_pure_argument_size`, 16384): a
/// String arg serializes as a 2-byte ULEB128 length prefix plus its bytes, so
/// 16383 would be rejected by the node before Move runs. This sits ~1.4KB under
/// that — note the ceiling is a protocol config, not a constant, so it could in
/// principle move.
///
/// Exposed as `max_comment_len()` so a frontend counter reads the live limit
/// instead of hard-coding a copy. A body this long must be truncated for
/// display; nothing renders 15KB inline.
const MAX_COMMENT_LEN: u64 = 15000;

// === Events ===

/// Generic over the coin pair, like every other per-pool event: one
/// fully-instantiated MoveEventType filter subscribes to exactly one token's
/// comments. JSON-RPC cannot filter on event field contents, so a `pool_id`
/// field alone would force every consumer to ingest the whole platform.
///
/// There is deliberately no non-generic twin for a global feed. This module
/// emits exactly one event type, so `MoveEventModule { package, module:
/// "comment" }` already IS the cross-token firehose — unlike module `pool`,
/// whose module filter returns a mix, which is why `PoolCreatedEvent` has to be
/// non-generic. The envelope's `type` string carries the pair, so `base`/`quote`
/// TypeName fields would be pure duplication on the package's
/// highest-volume event.
public struct CommentPostedEvent<phantom Base, phantom Quote> has copy, drop {
    /// Read from the borrowed pool, never from a caller argument.
    pool_id: ID,
    /// Fresh, globally unique object address. NO OBJECT EXISTS AT IT — never
    /// `getObject` it. Unique, not random (see the module doc).
    comment_id: address,
    author: address,
    /// Parent comment id; `none` for a root comment. UNVERIFIED caller input —
    /// see the module doc.
    reply_to: Option<address>,
    body: String,
}

// === Posting ===

/// Posts a comment on `pool`; a reply when `reply_to` is `some(parent_id)`.
///
/// `pool` is borrowed immutably purely to prove the pool exists and to bind
/// `Base`/`Quote` to a real launch — it is never read beyond its id. That makes
/// the event self-certifying: seeing a `CommentPostedEvent<B, Q>` proves a
/// `Pool<B, Q>` with that `pool_id` exists. The borrow is free in practice,
/// since `cfg` is already a shared input and pays for consensus either way.
///
/// Allowed in every phase, including MIGRATED — the pool object outlives the
/// curve, and discussion should not stop at graduation.
///
/// No `Clock`: timestamps come from the event envelope's `timestampMs`, per the
/// package's event doctrine.
public fun post<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &Pool<Base, Quote>,
    body: String,
    reply_to: Option<address>,
    ctx: &mut TxContext,
) {
    cfg.assert_version();
    // Pause-gated like `buy`, not exempt like `sell`: a comment is a
    // discretionary new write, not a path a user needs to exit a position.
    cfg.assert_not_paused();
    // Fail loudly rather than coerce: an over-long body aborts, it is never
    // truncated; an empty body aborts, it is never defaulted.
    assert!(!body.is_empty(), EEmptyComment);
    assert!(body.length() <= MAX_COMMENT_LEN, ECommentTooLong);

    let comment_id = ctx.fresh_object_address();
    event::emit(CommentPostedEvent<Base, Quote> {
        pool_id: object::id(pool),
        comment_id,
        author: ctx.sender(),
        reply_to,
        body,
    });
}

// === Views ===

public fun max_comment_len(): u64 { MAX_COMMENT_LEN }

// === Test helpers ===

#[test_only]
/// Returns `(pool_id, comment_id, author, reply_to, body)`.
public fun comment_posted_event_fields<Base, Quote>(
    ev: &CommentPostedEvent<Base, Quote>,
): (ID, address, address, Option<address>, String) {
    (ev.pool_id, ev.comment_id, ev.author, ev.reply_to, ev.body)
}
