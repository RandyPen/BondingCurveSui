/// Minimal base-coin template for launching on the bonding curve.
///
/// The whole package is just the coin type plus an `init` that delegates coin
/// creation to the launchpad. The launchpad's `seal` runs the UNREGULATED
/// currency constructor, so the coin provably has no `DenyCapV2`; decimals are
/// fixed by the launchpad (9). An agent copies this module, renames the type,
/// and edits the symbol / name / description / icon below.
module agent_coin_template::token;

use bondingcurvesui::pool;
use std::string;

/// One-time witness. Rename this (and the module) per launch; its uppercased
/// name must match the module name.
public struct TOKEN has drop {}

fun init(otw: TOKEN, ctx: &mut TxContext) {
    // The only thing this package does: hand the OTW to the launchpad, which
    // creates the currency and returns a receipt. Transfer the receipt to the
    // publisher, who then calls `finalize_registration` + `pool::create_token`.
    let receipt = pool::seal(
        otw,
        string::utf8(b"TICKER"),
        string::utf8(b"Token Name"),
        string::utf8(b"Short description of the token."),
        string::utf8(b""), // icon URL
        ctx,
    );
    transfer::public_transfer(receipt, ctx.sender());
}
