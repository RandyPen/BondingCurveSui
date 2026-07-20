#[test_only]
module bondingcurvesui::comment_tests;

use std::string::String;
use std::unit_test;
use sui::clock::{Self, Clock};
use sui::coin_registry::Currency;
use sui::test_scenario::{Self as ts, Scenario};

use bondingcurvesui::comment::{Self, CommentPostedEvent};
use bondingcurvesui::config::{Self, AdminCap, LaunchpadConfig};
use bondingcurvesui::mock_quote::MOCK_QUOTE;
use bondingcurvesui::mocks;
use bondingcurvesui::pool::{Self, Pool};
use bondingcurvesui::zzz_base::ZZZ_BASE;

const ADMIN: address = @0xAD;
const CREATOR: address = @0xC0FFEE;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

const THRESHOLD: u64 = 3_000_000_000;
const MIN_THRESHOLD: u64 = 1_000_000_000;
const CREATION_FEE: u64 = 10_000_000;
const MIN_BUY: u64 = 1_000;
const MIN_TVL_TARGET: u64 = 1_000;

// === Setup helpers ===

fun setup(): (Scenario, Clock) {
    let mut scenario = ts::begin(ADMIN);
    config::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::add_quote<MOCK_QUOTE>(
            &admin_cap,
            &mut cfg,
            6,
            THRESHOLD,
            MIN_THRESHOLD,
            CREATION_FEE,
            MIN_BUY,
            MIN_TVL_TARGET,
        );
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    let clock = clock::create_for_testing(scenario.ctx());
    (scenario, clock)
}

fun create_test_token(scenario: &mut Scenario, clock: &Clock): Currency<ZZZ_BASE> {
    scenario.next_tx(CREATOR);
    let (receipt, mut currency) = pool::new_sealed_base_for_testing<ZZZ_BASE>(scenario.ctx());
    let mut cetus_env = mocks::new_cetus_env(scenario.ctx());
    let mut cfg = scenario.take_shared<LaunchpadConfig>();
    let (cetus_config, cetus_pools) = cetus_env.cetus_refs();
    let change = pool::create_token<ZZZ_BASE, MOCK_QUOTE>(
        &mut cfg,
        &mut currency,
        receipt,
        mocks::mint_quote<MOCK_QUOTE>(CREATION_FEE, scenario.ctx()),
        option::none(),
        b"".to_string(),
        b"".to_string(),
        b"".to_string(),
        b"".to_string(),
        option::none(),
        option::none(),
        mocks::mint_quote<MOCK_QUOTE>(0, scenario.ctx()),
        cetus_config,
        cetus_pools,
        clock,
        scenario.ctx(),
    );
    transfer::public_transfer(change, CREATOR);
    ts::return_shared(cfg);
    mocks::destroy_cetus_env(cetus_env);
    currency
}

fun setup_with_pool(): (Scenario, Clock, Currency<ZZZ_BASE>) {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(&mut scenario, &clock);
    (scenario, clock, currency)
}

fun end(scenario: Scenario, clock: Clock, currency: Currency<ZZZ_BASE>) {
    clock.destroy_for_testing();
    unit_test::destroy(currency);
    scenario.end();
}

/// Posts as `author` in a fresh tx and returns the emitted comment id.
/// `events_by_type` reads only the current transaction, so the id must be
/// captured before the next `next_tx` drains the buffer.
fun post_as(
    scenario: &mut Scenario,
    author: address,
    body: String,
    reply_to: Option<address>,
): address {
    scenario.next_tx(author);
    let cfg = scenario.take_shared<LaunchpadConfig>();
    let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
    comment::post(&cfg, &pool, body, reply_to, scenario.ctx());
    ts::return_shared(cfg);
    ts::return_shared(pool);
    let events = sui::event::events_by_type<CommentPostedEvent<ZZZ_BASE, MOCK_QUOTE>>();
    assert!(events.length() == 1);
    let (_, comment_id, _, _, _) = comment::comment_posted_event_fields(&events[0]);
    comment_id
}

/// `unit` repeated `times` over, as a String. `repeat(b"a", 1000)` is 1000
/// bytes; `repeat(x"E5A5BD", 334)` is 334 CJK characters but 1002 bytes.
fun repeat(unit: vector<u8>, times: u64): String {
    let mut v = vector<u8>[];
    let mut i = 0;
    while (i < times) {
        v.append(unit);
        i = i + 1;
    };
    v.to_string()
}

// === Identity ===

#[test]
/// The premise the whole reply model rests on: `fresh_object_address` folds a
/// per-tx counter into the derivation, so two comments in ONE transaction get
/// distinct ids. `ctx.digest()` alone would collide here.
fun two_comments_in_one_tx_get_distinct_ids() {
    let (mut scenario, clock, currency) = setup_with_pool();
    scenario.next_tx(ALICE);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        comment::post(&cfg, &pool, b"first".to_string(), option::none(), scenario.ctx());
        comment::post(&cfg, &pool, b"second".to_string(), option::none(), scenario.ctx());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    let events = sui::event::events_by_type<CommentPostedEvent<ZZZ_BASE, MOCK_QUOTE>>();
    assert!(events.length() == 2);
    let (_, id0, _, _, _) = comment::comment_posted_event_fields(&events[0]);
    let (_, id1, _, _, _) = comment::comment_posted_event_fields(&events[1]);
    assert!(id0 != id1);
    end(scenario, clock, currency);
}

#[test]
fun comment_ids_differ_across_txs() {
    let (mut scenario, clock, currency) = setup_with_pool();
    let a = post_as(&mut scenario, ALICE, b"one".to_string(), option::none());
    let b = post_as(&mut scenario, ALICE, b"two".to_string(), option::none());
    assert!(a != b);
    end(scenario, clock, currency);
}

#[test]
fun root_comment_records_pool_author_and_body() {
    let (mut scenario, clock, currency) = setup_with_pool();
    scenario.next_tx(ALICE);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let expected_pool_id = object::id(&pool);
        comment::post(&cfg, &pool, b"gm".to_string(), option::none(), scenario.ctx());
        ts::return_shared(cfg);
        ts::return_shared(pool);

        let events = sui::event::events_by_type<CommentPostedEvent<ZZZ_BASE, MOCK_QUOTE>>();
        let (pool_id, _, author, reply_to, body) =
            comment::comment_posted_event_fields(&events[0]);
        // pool_id comes from the borrowed object, never from a caller arg.
        assert!(pool_id == expected_pool_id);
        assert!(author == ALICE);
        assert!(reply_to.is_none());
        assert!(body == b"gm".to_string());
    };
    end(scenario, clock, currency);
}

// === Threading ===

#[test]
fun reply_records_parent_id() {
    let (mut scenario, clock, currency) = setup_with_pool();
    let parent = post_as(&mut scenario, ALICE, b"gm".to_string(), option::none());
    scenario.next_tx(BOB);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        comment::post(&cfg, &pool, b"gm back".to_string(), option::some(parent), scenario.ctx());
        ts::return_shared(cfg);
        ts::return_shared(pool);

        let events = sui::event::events_by_type<CommentPostedEvent<ZZZ_BASE, MOCK_QUOTE>>();
        let (_, id, author, reply_to, _) = comment::comment_posted_event_fields(&events[0]);
        assert!(reply_to == option::some(parent));
        assert!(author == BOB);
        // A reply is a distinct comment, addressable by further replies.
        assert!(id != parent);
    };
    end(scenario, clock, currency);
}

#[test]
/// Pins the deliberate gap so nobody "fixes" it. The contract holds NO comment
/// state, so it cannot reject a fabricated parent: @0xDEAD is recorded verbatim
/// and the call succeeds. Rejecting the edge is the indexer's job — see
/// skills/launchpad-data/SKILL.md. If this test ever fails, someone added
/// state: re-read the module doc before proceeding.
fun forged_reply_to_is_accepted_on_chain_by_design() {
    let (mut scenario, clock, currency) = setup_with_pool();
    scenario.next_tx(ALICE);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        comment::post(&cfg, &pool, b"fake".to_string(), option::some(@0xDEAD), scenario.ctx());
        ts::return_shared(cfg);
        ts::return_shared(pool);

        let events = sui::event::events_by_type<CommentPostedEvent<ZZZ_BASE, MOCK_QUOTE>>();
        let (_, _, _, reply_to, _) = comment::comment_posted_event_fields(&events[0]);
        assert!(reply_to == option::some(@0xDEAD));
    };
    end(scenario, clock, currency);
}

/// Reimplements Sui's object-id derivation from PUBLIC primitives only:
/// `blake2b256(0xF1 || tx_digest || le_u64(ids_created))`. `tx_context::digest`,
/// `sui::hash::blake2b256` and `sui::address::from_bytes` are all public, so any
/// package can run this at execution time. The 0xF1 domain separator is a
/// constant (recoverable by a <=256-case brute force), NOT a secret.
fun predict_next_id(digest: vector<u8>, ids_created: u64): address {
    let mut preimage = vector<u8>[0xF1];
    preimage.append(digest);
    preimage.append(sui::bcs::to_bytes(&ids_created)); // BCS u64 == little-endian
    sui::address::from_bytes(sui::hash::blake2b256(&preimage))
}

#[test]
/// SECURITY: the reply graph is NOT acyclic. A caller can predict the id `post`
/// is about to mint and hand it straight back as `reply_to`, producing a comment
/// that replies to itself — a 1-cycle. Two such calls give a 2-cycle.
///
/// This works because `post` is `public fun`, so the prediction happens at
/// EXECUTION time from `ctx.digest()`. The "a pure argument can't contain a
/// value derived from its own tx digest" argument is true but irrelevant here:
/// nothing has to cross the argument boundary.
///
/// Consequence for consumers: never walk `reply_to` links unmemoized or without
/// a depth cap — see skills/launchpad-data/SKILL.md. If this test ever fails,
/// the derivation changed; the guidance still stands (2-cycles are unfixable
/// on-chain without storing comment state).
fun reply_graph_can_contain_a_cycle() {
    let (mut scenario, clock, currency) = setup_with_pool();
    scenario.next_tx(ALICE);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let ctx = scenario.ctx();

        // An attacker's own first PTB command knows this is 0; `ids_created()`
        // is test-only, but the VALUE is contextual knowledge, not a secret.
        let n = ctx.ids_created();
        let predicted = predict_next_id(*ctx.digest(), n);

        comment::post(&cfg, &pool, b"i reply to myself".to_string(), option::some(predicted), ctx);
        ts::return_shared(cfg);
        ts::return_shared(pool);

        let events = sui::event::events_by_type<CommentPostedEvent<ZZZ_BASE, MOCK_QUOTE>>();
        let (_, comment_id, _, reply_to, _) = comment::comment_posted_event_fields(&events[0]);

        assert!(predicted == comment_id);                  // the prediction is exact
        assert!(reply_to == option::some(comment_id));     // ... and it is a self-reply
    };
    end(scenario, clock, currency);
}

// === Body validation ===

#[test, expected_failure(abort_code = comment::EEmptyComment)]
fun empty_body_rejected() {
    let (mut scenario, clock, currency) = setup_with_pool();
    post_as(&mut scenario, ALICE, b"".to_string(), option::none());
    end(scenario, clock, currency);
}

#[test]
fun max_length_body_accepted() {
    let (mut scenario, clock, currency) = setup_with_pool();
    let body = repeat(b"a", comment::max_comment_len());
    assert!(body.length() == 15000);
    post_as(&mut scenario, ALICE, body, option::none());
    end(scenario, clock, currency);
}

#[test]
/// The limit is bytes, so the CJK budget is exactly a third: 5000 characters
/// fit to the byte. Guards the pair of numbers a frontend counter must mirror.
fun exactly_5000_cjk_characters_accepted() {
    let (mut scenario, clock, currency) = setup_with_pool();
    let body = repeat(x"E5A5BD", 5000); // 好 x5000
    assert!(body.length() == comment::max_comment_len());
    post_as(&mut scenario, ALICE, body, option::none());
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = comment::ECommentTooLong)]
fun over_max_length_body_rejected() {
    let (mut scenario, clock, currency) = setup_with_pool();
    let body = repeat(b"a", comment::max_comment_len() + 1);
    post_as(&mut scenario, ALICE, body, option::none());
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = comment::ECommentTooLong)]
/// The limit is BYTES, not characters: 5001 CJK characters is 15003 bytes and
/// is rejected, though it is a third of the ASCII character budget.
fun length_limit_counts_bytes_not_characters() {
    let (mut scenario, clock, currency) = setup_with_pool();
    let body = repeat(x"E5A5BD", 5001); // 好 x5001
    assert!(body.length() == 15003);
    post_as(&mut scenario, ALICE, body, option::none());
    end(scenario, clock, currency);
}

// === Gating ===

#[test, expected_failure(abort_code = config::EPaused)]
fun comment_rejected_when_paused() {
    let (mut scenario, clock, currency) = setup_with_pool();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_paused(&admin_cap, &mut cfg, true);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    post_as(&mut scenario, ALICE, b"blocked".to_string(), option::none());
    end(scenario, clock, currency);
}

#[test]
/// No holder gate: discussion is how a token gets discovered, so someone
/// evaluating it before buying must be able to speak.
fun anyone_can_comment_without_holding_base() {
    let (mut scenario, clock, currency) = setup_with_pool();
    post_as(&mut scenario, BOB, b"never traded here".to_string(), option::none());
    end(scenario, clock, currency);
}

#[test]
/// No phase gate — structural, since `post` never sees the phase. This test
/// documents the intent against a future refactor that might add one.
fun comment_allowed_after_curve_completes() {
    let (mut scenario, clock, currency) = setup_with_pool();
    scenario.next_tx(ALICE);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let (base, change) = pool::buy(
            &cfg,
            &mut pool,
            mocks::mint_quote<MOCK_QUOTE>(THRESHOLD * 2, scenario.ctx()),
            0,
            option::none(),
            &clock,
            scenario.ctx(),
        );
        assert!(pool.phase() == pool::phase_completed());
        transfer::public_transfer(base, ALICE);
        transfer::public_transfer(change, ALICE);
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    post_as(&mut scenario, ALICE, b"we graduated".to_string(), option::none());
    end(scenario, clock, currency);
}
