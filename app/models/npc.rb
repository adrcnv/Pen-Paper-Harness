class Npc < Character
  # Non-player characters. Default class for materialized characters in the
  # world. Materializer spawns Npcs; Scene::Assembler's present_characters
  # returns Npcs. What an Npc knows about the past is read directly from
  # the event log via query_events(for_holder_id=npc.id) — there is no
  # separate Belief store.
end
