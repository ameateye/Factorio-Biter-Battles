local out={}
out[#out+1]="TT1"
out[#out+1]=tostring(storage.bb_game_won_by_team or "")
out[#out+1]=tostring(storage.bb_game_start_tick or -1)
out[#out+1]=tostring(game.tick)
out[#out+1]=tostring((storage.bb_evolution and storage.bb_evolution.north_biters) or -1)
out[#out+1]=tostring((storage.bb_evolution and storage.bb_evolution.south_biters) or -1)
out[#out+1]=tostring((storage.bb_threat and storage.bb_threat.north_biters) or 0)
out[#out+1]=tostring((storage.bb_threat and storage.bb_threat.south_biters) or 0)
out[#out+1]=tostring(storage.victory_time or "")
out[#out+1]=tostring(storage.difficulty_vote_value or 0)
out[#out+1]=tostring(storage.tournament_mode == true)
local cn,cs,cx={},{},{}
for _,p in pairs(game.connected_players) do
  if p.force.name=="north" then cn[#cn+1]=p.name
  elseif p.force.name=="south" then cs[#cs+1]=p.name
  else cx[#cx+1]=p.name end
end
out[#out+1]=table.concat(cn,",")
out[#out+1]=table.concat(cs,",")
out[#out+1]=table.concat(cx,",")
local fn,fs={},{}
local FN=game.forces["north"]; if FN then for _,p in pairs(FN.players) do fn[#fn+1]=p.name end end
local FS=game.forces["south"]; if FS then for _,p in pairs(FS.players) do fs[#fs+1]=p.name end end
out[#out+1]=table.concat(fn,",")
out[#out+1]=table.concat(fs,",")
rcon.print(table.concat(out,"\t"))
