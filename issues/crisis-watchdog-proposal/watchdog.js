// PROPOSAL — not yet integrated. Add to functions/index.js on approval.
// Crisis-page delivery watchdog: scheduled backstop that catches any
// explicit-crisis page that never reached an admin, regardless of cause.
exports.crisisDeliveryWatchdog = onSchedule(
  { schedule: "every 5 minutes", timeoutSeconds: 120 },
  async () => {
    const now = Date.now();
    const cutoff = Timestamp.fromDate(new Date(now - 15 * 60 * 1000));       // >15 min old
    const floor  = Timestamp.fromDate(new Date(now - 24 * 60 * 60 * 1000));  // scan bound
    const undelivered = new Set();

    // (1) Persisted no-token records older than 15m with still no delivery
    //     claim. Keyed by the page's claim id, so this SURVIVES post deletion —
    //     a crisis post deleted before 15m is still caught here if its page
    //     failed on no-token.
    const recs = await db.collection("undeliveredCrisisPages")
      .where("detectedAt", "<", cutoff).get();
    for (const d of recs.docs) {
      const claim = await db.collection("processedTriggerEvents").doc(d.id).get();
      if (!claim.exists) undelivered.add(d.id.replace(/^crisisAlert_/, ""));
    }

    // (2) Live concerning posts 15m–24h old with no delivery claim — catches the
    //     transient-send-failure path (tokens existed, all sends failed, retries
    //     exhausted) that leaves no record. Uses the existing
    //     (concerningContent, createdAt) composite index.
    const posts = await db.collection("posts")
      .where("concerningContent", "==", true)
      .where("createdAt", "<", cutoff)
      .where("createdAt", ">", floor).get();
    for (const p of posts.docs) {
      const claim = await db.collection("processedTriggerEvents").doc(`crisisAlert_${p.id}`).get();
      if (!claim.exists) undelivered.add(p.id);
    }

    // WARNING severity (not error) so this trips ONLY the dedicated undelivered
    // alert, not the generic "all other functions" error policy (no double-alert).
    for (const postId of undelivered) {
      console.warn(JSON.stringify({ tag: "crisis_page_undelivered", postId }));
    }
    // Heartbeat every run — a separate absence alert fires if this stops.
    console.log(JSON.stringify({ tag: "crisis_watchdog_heartbeat", undelivered: undelivered.size }));
  }
);
