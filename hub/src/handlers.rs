//! Control-frame handlers for the hub's main loop.
//!
//! Each `handle_*` is the body of one `if ty == "..."` branch of `run_hub`,
//! moved here verbatim. `run_hub` still decides which frame is which; these
//! functions only act on it. They borrow the loop's state through [`Ctl`].

use super::*;

/// Everything the control-frame handlers borrow from `run_hub`'s loop.
pub(crate) struct Ctl<'a> {
    pub sock: &'a zmq::Socket,
    pub state: &'a mut HubState,
    pub shared: &'a SharedState,
    pub audit: &'a std::sync::Arc<audit::Audit>,
    pub cfg: &'a std::sync::Arc<config::ConfigStore>,
    pub cmds: &'a std::sync::Arc<commands::CommandStore>,
    pub st: &'a mut Stats,
    pub args: &'a Args,
    pub local_zmq: &'a String,
    pub peer_zmq: &'a String,
    pub started: Instant,
    pub wire_audit_throttle: &'a mut HashMap<(String, String), Instant>,
    pub last_cfg_pull: &'a mut HashMap<String, (Instant, u32)>,
    pub last_cfgr_print: &'a mut HashMap<String, Instant>,
    pub last_rcpt_relayed: &'a mut HashMap<(String, String), (String, Instant)>,
    pub last_rcpt_prune: &'a mut Instant,
    pub last_rcpt_drop: &'a mut Instant,
    pub poke_pending: &'a mut bool,
}


/// PING: hub liveness probe -> PONG.
#[allow(unused_variables, unused_mut)]
pub(crate) fn handle_ping(c: Ctl<'_>, payload: &Vec<u8>, ty: &String) {
    let Ctl { sock, mut state, shared, audit, cfg, cmds, mut st, args, local_zmq, peer_zmq, started, mut wire_audit_throttle, mut last_cfg_pull, mut last_cfgr_print, mut last_rcpt_relayed, mut last_rcpt_prune, mut last_rcpt_drop, poke_pending } = c;
    let nid = envelope_kv(&payload, "FROM");
    let ms = envelope_kv(&payload, "MS");
    //--- C2: reply only to something that can be a node id.
    //--- FROM is chosen by the publisher, so accepting any string
    //--- made the hub a generic "publish to an arbitrary topic"
    //--- primitive. A real node id is all digits.
    let nid_plausible = !nid.is_empty()
        && nid.len() <= 11
        && nid.bytes().all(|b| b.is_ascii_digit());
    if nid_plausible && !ms.is_empty() {
        {
            let s = shared.lock_or_recover();
            if state.role != s.cluster.state.role {
                state.role = s.cluster.state.role.clone();
            }
        }
        if let Err(e) = send_pong(&sock, &nid, &ms, &mut state) {
            eprintln!("[hub] PONG failed: {}", e);
        }
    }
}

/// REG / HBT2: node registration, heartbeat, config drift and topology.
#[allow(unused_variables, unused_mut)]
pub(crate) fn handle_reg(c: Ctl<'_>, payload: &Vec<u8>, ty: &String) {
    let Ctl { sock, mut state, shared, audit, cfg, cmds, mut st, args, local_zmq, peer_zmq, started, mut wire_audit_throttle, mut last_cfg_pull, mut last_cfgr_print, mut last_rcpt_relayed, mut last_rcpt_prune, mut last_rcpt_drop, poke_pending } = c;
    let (effective_writes, is_prim) = {
        let s = shared.lock_or_recover();
        (s.writes, s.cluster.is_primary())
    };
    let role = envelope_kv(&payload, "ROLE");
    let acc = envelope_kv(&payload, "ACC");
    if acc.is_empty() {
        //--- ACC is the identity. Without it the node
        //--- cannot even be addressed, so it is not a
        //--- node - it is a message with no return
        //--- address, and saying so beats filing it
        //--- under an empty key forever.
        let throttle_key = ("wire".to_string(), "node.malformed".to_string());
        let should_audit = match wire_audit_throttle.get(&throttle_key) {
            Some(t) => t.elapsed() >= Duration::from_secs(10),
            None => true,
        };
        if should_audit {
            wire_audit_throttle.insert(throttle_key, Instant::now());
            println!("[hub] WARN  {} with no ACC - not registered", ty);
            audit.record(
                "", "",
                "node.malformed",
                "",
                None,
                Some(serde_json::json!({ "type": ty, "role": role })),
                "rejected",
            );
        }
    } else {
        let ver = envelope_kv(&payload, "VER");
        let up: u64 = envelope_kv(&payload, "UP").parse().unwrap_or(0);
        let now = Instant::now();
        //--- The node's own config revision, if it has
        //--- one. Recorded for every REG and HBT2 so
        //--- the view stays current, and used below to
        //--- decide whether the hub owes it a push.
        // P2-5: Differentiate between missing REV field vs REV=0 (cleared/reset config)
        let rev_str = envelope_kv(&payload, "REV");
        let node_rev: u64 = if !rev_str.is_empty() {
            rev_str.parse().unwrap_or(0)
        } else {
            0
        };
        if !rev_str.is_empty() {
            let mut s = shared.lock_or_recover();
            let node_key = format!("{}:{}", role, acc);
            if node_rev > 0 {
                s.node_rev.insert(node_key, node_rev);
            } else {
                s.node_rev.remove(&node_key);
            }
        }
        //--- M6: the node's own clock, for drift
        //--- detection. REG and HBT2 both carry TS.
        //--- Captured here but APPLIED BELOW, after
        //--- on_reg/on_hbt has had its say: note_ts
        //--- deliberately does not create nodes (a
        //--- STAT must not), and a call that lands
        //--- before the registration would silently
        //--- no-op on a node's very first REG - the
        //--- baseline would never be set and no drift
        //--- could ever fire.
        let node_ts: i64 =
            envelope_hdr(&payload, "TS").parse().unwrap_or(0);
        let node_gts: i64 =
            envelope_hdr(&payload, "GTS").parse().unwrap_or(0);
        if ty == "REG" || ty == "HBT2" {
            // Phase 4 / BUG-04: Send T=TOPOLOGY to node on registration and on heartbeat if topology changed
            let (is_prim, cur_epoch, cur_role, dynamic_peer_zmq) = {
                let s = shared.lock_or_recover();
                (
                    s.cluster.is_primary(),
                    s.cluster.epoch(),
                    s.cluster.role().to_string(),
                    s.cluster.peer_zmq.clone(),
                )
            };
            let active_peer_zmq = if !dynamic_peer_zmq.is_empty() {
                &dynamic_peer_zmq
            } else {
                &peer_zmq
            };
            let primary_ep = if is_prim { &local_zmq } else { active_peer_zmq };
            let standby_ep = if is_prim { active_peer_zmq } else { &local_zmq };
            let topo_key = (primary_ep.to_string(), standby_ep.to_string(), cur_epoch, cur_role.clone());
            let is_reg = ty == "REG";
            let should_send_topo = is_reg || match state.last_topo_sent.get(&acc) {
                Some(prev) => prev != &topo_key,
                None => true,
            };
            if (!primary_ep.is_empty() || !standby_ep.is_empty()) && should_send_topo {
                if send_topology(
                    &sock,
                    &acc,
                    primary_ep,
                    standby_ep,
                    cur_epoch,
                    &cur_role,
                    &mut state,
                ).is_ok() {
                    state.last_topo_sent.insert(acc.clone(), topo_key);
                }
            }
        }
        if ty == "REG" {

            let name = envelope_kv(&payload, "NAME");
            let node_key = format!("{}:{}", role, acc);
            let ih = envelope_kv(&payload, "IH");
            let ini_esc = envelope_kv(&payload, "INI");

            if role == "receiver" {
                if !ini_esc.is_empty() {
                    // Backward compatibility: legacy receiver reporting full INI on REG
                    let current_ini = config::unescape_ini(&ini_esc);
                    let chash = config::cfg_hash(&current_ini);
                    let mut s = shared.lock_or_recover();
                    s.node_current_ini.insert(node_key.clone(), api::CurrentSetting {
                        ini: current_ini,
                        ts: unix_secs(),
                        hash: chash,
                    });
                } else if !ih.is_empty() {
                    // Modern receiver: 32-byte content hash comparison
                    let needs_pull = {
                        let s = shared.lock_or_recover();
                        match s.node_current_ini.get(&node_key) {
                            Some(cur) => cur.hash != ih,
                            None => true, // hub has no record yet (e.g. freshly restarted)
                        }
                    };
                    if needs_pull {
                        let (throttled, attempts) = match last_cfg_pull.get(&node_key) {
                            Some(&(last_t, attempts)) => {
                                // First retry allowed after 5s for fast bootstrap/reconnect recovery;
                                // subsequent retries back off to 60s, and to 1800s (30m) after 5 attempts (BUG-85-06)
                                // to prevent command flood and repeated timeouts against legacy receivers.
                                let delay = if attempts <= 1 {
                                    Duration::from_secs(5)
                                } else if attempts < 5 {
                                    Duration::from_secs(60)
                                } else {
                                    Duration::from_secs(1800)
                                };
                                (last_t.elapsed() < delay, attempts)
                            }
                            None => (false, 0),
                        };
                        if !throttled {
                            // P1-1 / BUG-06: Primary issues reqcfg to fetch EA current config even in read-only (--writes off) mode
                            if is_prim {
                                last_cfg_pull.insert(node_key.clone(), (Instant::now(), attempts + 1));
                                println!("[hub] {} reports IH={} (mismatch or empty) - requesting full config via reqcfg (attempt {})", node_key, ih, attempts + 1);
                                cmds.issue_op(&node_key, "reqcfg", "", "hub", "127.0.0.1");
                            }
                        }
                    }
                }
            }
            //--- captured BEFORE the update, because
            //--- "it had no name and now it does" is
            //--- the event worth reporting.
            let was_unnamed = {
                let s = shared.lock_or_recover();
                s.reg.is_unnamed(&role, &acc)
            };
            let is_new = {
                let mut s = shared.lock_or_recover();
                let n = s.reg.on_reg(&role, &acc, &ver, &name, up, now);
                n
            };
            *poke_pending = true;
            if is_new {
                println!(
                    "[hub] +node {:<20} {:<16} ver {} up {}s",
                    format!("{}:{}", role, acc),
                    if name.is_empty() { "-" } else { name.as_str() },
                    if ver.is_empty() { "?" } else { ver.as_str() },
                    up
                );
                let throttle_key = ("wire".to_string(), "node.registered".to_string());
                let should_audit = match wire_audit_throttle.get(&throttle_key) {
                    Some(t) => t.elapsed() >= Duration::from_millis(500),
                    None => true,
                };
                if should_audit {
                    wire_audit_throttle.insert(throttle_key, Instant::now());
                    audit.record(
                        "", "",
                        "node.registered",
                        &format!("{}:{}", role, acc),
                        None,
                        Some(serde_json::json!({
                            "role": role,
                            "acc": acc,
                            "name": name,
                            "ver": ver,
                            "up_secs": up,
                        })),
                        "ok",
                    );
                }
            } else if was_unnamed && !name.is_empty() {
                //--- The lost-REG race resolving. Worth a
                //--- line: until this arrives the node is
                //--- a row nobody can identify.
                println!(
                    "[hub] named {:<20} {}",
                    format!("{}:{}", role, acc),
                    name
                );
                audit.record(
                    "", "",
                    "node.named",
                    &format!("{}:{}", role, acc),
                    Some(serde_json::json!({ "name": "" })),
                    Some(serde_json::json!({ "name": name })),
                    "ok",
                );
            }
        } else {
            // NAME too, since the HBT2 change: a node
            // that only heartbeats used to be visible
            // but anonymous until a WHO sweep made it
            // re-REG - ten to fifteen seconds of blank
            // Name cells after a hub restart with the
            // EAs already attached.
            //
            // Read OUTSIDE the lock and outside the
            // block, because the reporting below needs
            // it as well as the registry does.
            let nm = envelope_kv(&payload, "NAME");
            let is_new = {
                let mut s = shared.lock_or_recover();
                s.reg.on_hbt(&role, &acc, &ver, &nm, up, now)
            };
            *poke_pending = true;
            //--- A node introduced by its HEARTBEAT means its
            //--- REG never arrived - the EAs' socket is
            //--- IMMEDIATE, so a send made before the TCP
            //--- connection completes is discarded rather
            //--- than queued. The node is real, so it is
            //--- reported; but it is ANONYMOUS, and saying
            //--- so is the difference between a row nobody
            //--- can identify and a known race.
            if is_new {
                //--- The old wording here said "no NAME
                //--- yet, its REG was lost", which was
                //--- true until HBT2 started carrying
                //--- NAME. What is lost is the REG, not
                //--- the name, and the distinction is
                //--- the whole point of the HBT2 change.
                println!(
                    "[hub] +node {:<20} {:<16} ver {} up {}s  \
                     (from HBT2 - its REG was lost)",
                    format!("{}:{}", role, acc),
                    if nm.is_empty() { "-" } else { nm.as_str() },
                    if ver.is_empty() { "?" } else { ver.as_str() },
                    up
                );
                let throttle_key = ("wire".to_string(), "node.registered".to_string());
                let should_audit = match wire_audit_throttle.get(&throttle_key) {
                    Some(t) => t.elapsed() >= Duration::from_millis(500),
                    None => true,
                };
                if should_audit {
                    wire_audit_throttle.insert(throttle_key, Instant::now());
                    audit.record(
                        "", "",
                        "node.registered",
                        &format!("{}:{}", role, acc),
                        None,
                        Some(serde_json::json!({
                            "role": role,
                            "acc": acc,
                            "name": nm,
                            "via": "heartbeat",
                            "note": "its REG was lost",
                        })),
                        "ok",
                    );
                }
            } else if args.verbose {
                println!(
                    "[hub] hbt   {:<20} up {}s",
                    format!("{}:{}", role, acc),
                    up
                );
            }
        }

        //--- M6: the node's clock, now that the node
        //--- exists (REG created it, or HBT2 implies
        //--- it registered earlier). Baseline on the
        //--- first observation, jump-detect ever after.
        if node_ts > 0 || node_gts > 0 {
            let mut s = shared.lock_or_recover();
            s.reg.note_clocks(&role, &acc, node_ts, node_gts, unix_secs() as i64);
        }
        //--- M5b on the dashboard: the node's own
        //--- hub-pause report (PAUSED= on REG/HBT2).
        //--- A sender never sends it, and a missing
        //--- field means "not paused" - an old EA
        //--- simply predates the flag.
        {
            let paused = envelope_kv(&payload, "PAUSED");
            if !paused.is_empty() {
                let mut s = shared.lock_or_recover();
                s.reg.note_paused(&role, &acc, paused == "1");
            }
        }
        if let Ok(ping_ms) = envelope_kv(&payload, "PING").parse::<u64>() {
            let mut s = shared.lock_or_recover();
            s.reg.note_ping(&role, &acc, ping_ms);
        }

        //--- THE CONFIG COMPARISON (§7.3). Only for a
        //--- receiver: a sender has no ini to manage.
        //---
        //--- Three outcomes, and the middle one is the
        //--- one that must NOT be silent:
        //---   node < hub  -> the node is behind; push
        //---   node = hub  -> in step, nothing to do
        //---   node > hub  -> DRIFT. Somebody edited
        //---                    the node by hand.
        //--- §7.4 is explicit that this is reported,
        //--- not silently overwritten: the hub being
        //--- the source of truth does not make an
        //--- unexplained difference something to
        //--- erase.
        // R5-D5-05: Allow initial config push for receivers with REV=0
        if role == "receiver" {
            let key = format!("{}:{}", role, acc);
            let hub_rev = cfg.current(&key).map(|r| r.rev).unwrap_or(0);
            if hub_rev > 0 && node_rev > hub_rev {
                let throttle_key = (key.clone(), "config.drift".to_string());
                let should_audit = match wire_audit_throttle.get(&throttle_key) {
                    Some(t) => t.elapsed() >= Duration::from_secs(60),
                    None => true,
                };
                if should_audit {
                    wire_audit_throttle.insert(throttle_key, Instant::now());
                    println!(
                        "[hub] WARN  {} reports config REV {} but this hub \
                         issued {} - drifted, not overwriting",
                        key, node_rev, hub_rev
                    );
                    audit.record(
                        "",
                        "",
                        "config.drift",
                        &key,
                        Some(serde_json::json!({ "hub_rev": hub_rev })),
                        Some(serde_json::json!({ "node_rev": node_rev })),
                        "drift",
                    );
                }
            } else if hub_rev > 0 && node_rev < hub_rev && effective_writes && is_prim {
                if let Some(r) = cfg.current(&key) {
                    let c = cmds.issue_cfg(&key, r.rev, "", "");
                    let throttle_key = (key.clone(), "config.repush".to_string());
                    let should_audit = match wire_audit_throttle.get(&throttle_key) {
                        Some(t) => t.elapsed() >= Duration::from_secs(60),
                        None => true,
                    };
                    if should_audit {
                        wire_audit_throttle.insert(throttle_key, Instant::now());
                        println!(
                            "[hub] {} is behind (rev {} < {}) - pushing CFG {}",
                            key, node_rev, r.rev, c.id
                        );
                        audit.record(
                            "",
                            "",
                            "config.repush",
                            &key,
                            Some(serde_json::json!({ "node_rev": node_rev })),
                            Some(serde_json::json!({ "hub_rev": r.rev })),
                            "ok",
                        );
                    }
                }
            }
        }
    }
}

/// ACK: a node acknowledging a CFG or CMD.
#[allow(unused_variables, unused_mut)]
pub(crate) fn handle_ack(c: Ctl<'_>, payload: &Vec<u8>, ty: &String) {
    let Ctl { sock, mut state, shared, audit, cfg, cmds, mut st, args, local_zmq, peer_zmq, started, mut wire_audit_throttle, mut last_cfg_pull, mut last_cfgr_print, mut last_rcpt_relayed, mut last_rcpt_prune, mut last_rcpt_drop, poke_pending } = c;
    let id = envelope_kv(&payload, "ID");
    let ok = envelope_kv(&payload, "OK") == "1";
    let rev: u64 = envelope_kv(&payload, "REV").parse().unwrap_or(0);
    let err = envelope_kv(&payload, "ERR");
    let note = envelope_kv(&payload, "NOTE");
    let ack_msg = if !err.is_empty() { err.clone() } else { note };
    //--- The node and the KIND are derived from the
    //--- COMMAND, not from the message. An ACK carries no
    //--- ACC - it does not need one, because the id it
    //--- quotes already encodes the node (`<node>R<rev>`
    //--- or `<node>-<op>-<seq>`). Reading the node back
    //--- out of the command also means an ACK can only
    //--- ever be attributed to a node the hub actually
    //--- sent something to. The KIND decides which audit
    //--- action names the result.
    let (who, kind, op) = cmds
        .command(&id)
        .map(|c| (c.node, c.kind, c.op))
        .unwrap_or_else(|| ("?".to_string(), String::new(), String::new()));
    let prefix = if kind == commands::KIND_OP { "command" } else { "config" };
    let is_prim = shared.lock_or_recover().cluster.is_primary();
    if id.is_empty() {
        println!("[hub] WARN  ACK with no ID");
    } else if !is_prim {
        // BUG-06: ADR-03 Single-Writer invariant: Standby hub MUST NOT process
        // ACKs or mutate commands.jsonl. Primary alone processes ACKs, and Standby
        // replicates acked command journals via HTTP cluster sync.
    } else if cmds.ack(&id, ok, rev, &ack_msg) {
        println!(
            "[hub] {} {} {} ({} {}) rev {}",
            who,
            if ok { "applied" } else { "REJECTED" },
            id,
            prefix,
            op,
            rev
        );
        let action = if ok {
            format!("{}.acked", prefix)
        } else {
            format!("{}.rejected", prefix)
        };
        audit.record(
            "",
            "",
            &action,
            &who,
            None,
            Some(serde_json::json!({
                "id": id, "kind": kind, "op": op, "rev": rev, "err": err,
            })),
            if ok { "ok" } else { "rejected" },
        );
    } else {
        //--- R59-04: ack() returns false for two very
        //--- different situations - an id this hub never
        //--- issued, and a duplicate/late ACK for one that is
        //--- already at its final state. Saying "never sent"
        //--- for the second sent operators hunting for a
        //--- forger when the real story was a retry.
        println!(
            "[hub] WARN  {} ACKed {} - unknown id, already terminal (late/duplicate ACK), or the journal append failed (see the line above)",
            who, id
        );
        // `prefix` is "config" here only because the
        // unknown id left `kind` empty - derive it from
        // the id's shape instead (see unknown_ack_prefix).
        let action = format!("{}.unknown_ack", unknown_ack_prefix(&id));
        let throttle_key = (who.clone(), action.clone());
        let should_audit = match wire_audit_throttle.get(&throttle_key) {
            Some(t) => t.elapsed() >= Duration::from_secs(10),
            None => true,
        };
        if should_audit {
            wire_audit_throttle.insert(throttle_key, Instant::now());
            audit.record(
                "",
                "",
                &action,
                &who,
                None,
                Some(serde_json::json!({ "id": id })),
                "unknown",
            );
        }
    }
}

/// CFGR: a node asking for its config.
#[allow(unused_variables, unused_mut)]
pub(crate) fn handle_cfgr(c: Ctl<'_>, payload: &Vec<u8>, ty: &String) {
    let Ctl { sock, mut state, shared, audit, cfg, cmds, mut st, args, local_zmq, peer_zmq, started, mut wire_audit_throttle, mut last_cfg_pull, mut last_cfgr_print, mut last_rcpt_relayed, mut last_rcpt_prune, mut last_rcpt_drop, poke_pending } = c;
    let (effective_writes, is_prim) = {
        let s = shared.lock_or_recover();
        (s.writes, s.cluster.is_primary())
    };
    //--- CFGR DOES carry ACC (the plan's §5.2), because
    //--- unlike an ACK there is no command id to derive
    //--- the node from - the node is asking for
    //--- something the hub may not have sent yet.
    let crole = envelope_kv(&payload, "ROLE");
    let cacc = envelope_kv(&payload, "ACC");
    let key = if crole.is_empty() {
        format!("receiver:{}", cacc)
    } else {
        format!("{}:{}", crole, cacc)
    };
    if effective_writes && is_prim {
        let should_log = match last_cfgr_print.get(&key) {
            Some(t) => t.elapsed() >= Duration::from_secs(10),
            None => true,
        };
        match cfg.current(&key) {
            Some(r) => {
                let c = cmds.issue_cfg(&key, r.rev, "", "");
                if should_log {
                    last_cfgr_print.insert(key.clone(), Instant::now());
                    println!(
                        "[hub] {} asked for its config - queued {} (rev {})",
                        key, c.id, r.rev
                    );
                }
            }
            None => {
                if should_log {
                    last_cfgr_print.insert(key.clone(), Instant::now());
                    println!(
                        "[hub] {} asked for its config but this hub has none",
                        key
                    );
                }
            }
        }
    }
}

/// CFGRPT: a receiver reporting its effective config.
#[allow(unused_variables, unused_mut)]
pub(crate) fn handle_cfgrpt(c: Ctl<'_>, payload: &Vec<u8>, ty: &String) {
    let Ctl { sock, mut state, shared, audit, cfg, cmds, mut st, args, local_zmq, peer_zmq, started, mut wire_audit_throttle, mut last_cfg_pull, mut last_cfgr_print, mut last_rcpt_relayed, mut last_rcpt_prune, mut last_rcpt_drop, poke_pending } = c;
    let crole = envelope_kv(&payload, "ROLE");
    let cacc = envelope_kv(&payload, "ACC");
    let ini_esc = envelope_kv(&payload, "INI");
    let rev: u64 = envelope_kv(&payload, "REV").parse().unwrap_or(0);
    let key = if crole.is_empty() {
        format!("receiver:{}", cacc)
    } else {
        format!("{}:{}", crole, cacc)
    };
    let is_registered = {
        let s = shared.lock_or_recover();
        s.reg.get(&key).is_some()
    };
    if is_registered && !ini_esc.is_empty() {
        let current_ini = config::unescape_ini(&ini_esc);
        let chash = config::cfg_hash(&current_ini);
        let mut s = shared.lock_or_recover();
        s.node_current_ini.insert(key.clone(), api::CurrentSetting {
            ini: current_ini,
            ts: unix_secs(),
            hash: chash,
        });
        // BUG-08: Confirm node revision in node_rev even if rev == 0
        s.node_rev.insert(key.clone(), rev);
    }
    println!("[hub] {} reported current effective config (rev {})", key, rev);
    last_cfg_pull.remove(&key);
    *poke_pending = true;
}

/// STAT: node status, positions and snapshot receipts.
#[allow(unused_variables, unused_mut)]
pub(crate) fn handle_stat(c: Ctl<'_>, payload: &Vec<u8>, ty: &String) {
    let Ctl { sock, mut state, shared, audit, cfg, cmds, mut st, args, local_zmq, peer_zmq, started, mut wire_audit_throttle, mut last_cfg_pull, mut last_cfgr_print, mut last_rcpt_relayed, mut last_rcpt_prune, mut last_rcpt_drop, poke_pending } = c;
    let login = envelope_kv(&payload, "LOGIN");
    if !login.is_empty() {
        let role_raw = envelope_kv(&payload, "ROLE");
        let role = if role_raw == "sender" { "sender" } else { "receiver" };
        let sid = envelope_kv(&payload, "SID");
        let h = envelope_kv(&payload, "H");
        //--- M6: the risk state rides the SAME STAT the
        //--- receipt does. BLOCKED counts entries the
        //--- receiver's risk gate is holding back;
        //--- RISK names the limit when one tripped.
        let blocked: u32 =
            envelope_kv(&payload, "BLOCKED").parse().unwrap_or(0);
        let risk = envelope_kv(&payload, "RISK");
        //--- Position figures ride receipt heartbeats
        //--- (default 1s); full RISK/BLOCKED data is
        //--- only included in the minute report.
        let held: Option<u32> =
            envelope_kv(&payload, "HELD").parse().ok();
        let parse_finite_f64 = |s: &str| -> Option<f64> {
            s.parse::<f64>().ok().filter(|v| v.is_finite())
        };
        let held_lots: f64 =
            parse_finite_f64(&envelope_kv(&payload, "LOTS")).unwrap_or(0.0);
        let orphaned: Option<u32> =
            envelope_kv(&payload, "ORPHAN").parse().ok();
        let wait_total: Option<u32> =
            envelope_kv(&payload, "WAIT").parse().ok();
        let wait_lots: f64 =
            parse_finite_f64(&envelope_kv(&payload, "WLOTS")).unwrap_or(0.0);
        let wait_queued: Option<u32> =
            envelope_kv(&payload, "WQUEUED").parse().ok();
        let wait_delayed: Option<u32> =
            envelope_kv(&payload, "WDELAYED").parse().ok();
        let wait_mkt: Option<u32> =
            envelope_kv(&payload, "WMKT").parse().ok();
        let equity: Option<f64> =
            parse_finite_f64(&envelope_kv(&payload, "EQ"));
        let balance: Option<f64> =
            parse_finite_f64(&envelope_kv(&payload, "BL"));
        // P2-11: Only parse heavy POS & WAITLIST if STAT carries summary fields
        let need_stat = !risk.is_empty() || held.is_some() || wait_total.is_some() || equity.is_some();
        let (held_items, wait_items) = if need_stat {
            let h = envelope_kv_opt(&payload, "POS")
                .map(|s| registry::parse_receiver_positions(&s));
            let w = envelope_kv_opt(&payload, "WAITLIST")
                .map(|s| registry::parse_receiver_waitlist(&s));
            (h, w)
        } else {
            (None, None)
        };

        //--- one lock for the frame-level telemetry. The
        //--- per-sender validation and mirror edge moved into
        //--- relay_one_receipt() so the single (`SID=`/`H=`) and
        //--- batched (`RH=`) receipt forms cannot drift apart.
        let mut stat_changed = false;
        {
            let mut s = shared.lock_or_recover();
            if need_stat {
                s.reg.note_stat(
                    role,
                    &login,
                    blocked,
                    &risk,
                    held,
                    held_lots,
                    orphaned,
                    wait_total,
                    wait_lots,
                    wait_queued,
                    wait_delayed,
                    wait_mkt,
                    equity,
                    balance,
                    held_items,
                    wait_items,
                );
                stat_changed = true;
            }
            if let Ok(ping_ms) = envelope_kv(&payload, "PING").parse::<u64>() {
                s.reg.note_ping(role, &login, ping_ms);
                stat_changed = true;
            }
        }

        //--- B5/P4: ONE frame can carry MANY receipts.
        //--- `RH=<sid>:<h>,<sid>:<h>,...` is the batched form a
        //--- receiver now sends when it mirrors more than one
        //--- sender; the original single `SID=`/`H=` form is still
        //--- accepted (and is still repeated on the first batched
        //--- frame, so an older hub receives one receipt instead
        //--- of none).
        if role == "receiver" {
            let warm = started.elapsed() < Duration::from_secs(60);
            let rh_raw = envelope_kv(&payload, "RH");
            let mut pairs: Vec<(String, String)> = parse_rh_pairs(&rh_raw);
            if pairs.is_empty() && !sid.is_empty() && sid != "-" {
                pairs.push((sid.clone(), h.clone()));
            }
            if relay_receipts(
                &sock,
                &mut state,
                &shared,
                &mut st,
                warm,
                &login,
                &pairs,
                &mut last_rcpt_relayed,
                &mut last_rcpt_prune,
                &mut last_rcpt_drop,
            ) {
                stat_changed = true;
            }
        }

        if stat_changed {
            *poke_pending = true;
        }
    }
}
