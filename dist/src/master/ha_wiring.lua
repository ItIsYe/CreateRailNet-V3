








local ha_module=require("src.shared.ha")
local election_store=require("src.shared.election_store")
local barrier_module=require("src.master.barrier")
local guarded_adapters=require("src.master.guarded_adapters")
local replica_module=require("src.master.replica")
local journal_module=require("src.shared.journal")
local storage_budget=require("src.shared.storage_budget")

local ha_wiring={}

function ha_wiring.prepare(cfg,id,opts)
if not ha_module.is_ha(cfg)then return nil end
opts=opts or{}
local prep={id=id,cfg=cfg}
prep.barrier=barrier_module.new({now_ms=opts.now_ms,logger=opts.logger})

prep.leader_ref={is_leader=function()return prep.leader_ref.ha~=nil and prep.leader_ref.ha.is_leader()end}
function prep.signals(adapter)return guarded_adapters.guard(adapter,{barrier=prep.barrier,ha=prep.leader_ref,kind="signals"})end
function prep.switches(adapter)return guarded_adapters.guard(adapter,{barrier=prep.barrier,ha=prep.leader_ref,kind="switches"})end
return prep
end

function ha_wiring.finish(prep,opts)
local cfg,id,network,logger=prep.cfg,prep.id,opts.network,opts.logger
local ha=ha_module.new({
id=id,config=cfg,network=network,now_ms=opts.now_ms,logger=logger,
store=opts.election_store or election_store.new(cfg.election_state_file),
lease_ms=cfg.election_lease_ms,beat_ms=cfg.election_beat_ms
})
network.gate,network.stamp=ha.gate,ha.stamp
prep.leader_ref.ha=ha

local partner
for _,master in ipairs(cfg.masters)do if master~=id then partner=master end end
local journal=opts.journal or journal_module.new(cfg.master_journal_file or "state/master_journal.log",{max_entries=storage_budget.JOURNAL.master.max_entries,max_bytes=storage_budget.JOURNAL.master.max_bytes,max_snapshot_bytes=storage_budget.SNAPSHOT_MAX_BYTES})
local journal_state,journal_info=journal.open()
if(journal_state=="corrupt" or journal_state=="failed")and logger then
logger.error("master journal unusable: no dual commit, no movement is given",{status=journal_state,reason=journal_info and journal_info.reason})
end
local replica=replica_module.new({
id=id,peer=partner,network=network,journal=journal,ha=ha,logger=logger,now_ms=opts.now_ms,
snapshot_fn=function()return opts.dispatcher.snapshot({replicated=true})end
})
ha.dual_commit={permissive=barrier_module.permissive_cmd,writable=replica.writable}
network.hold=prep.barrier.hold

if opts.dispatcher.require_commit then opts.dispatcher.require_commit(true)end
return{ha=ha,replica=replica,barrier=prep.barrier,journal=journal}
end

return ha_wiring
