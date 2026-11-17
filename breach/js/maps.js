// Mission definitions. Grid maps: 1 char = 1 m.
//  #  wall          D  door            K  locked door (kick / shotgun breach)
//  W  window        X  crate (cover)   L  hanging lamp
//  P  spawn         E  extraction      S  hostage
//  h  hostile (standing)   H  hostile (pop-up, rises when you get close)
//  c  civilian (standing)  C  civilian (pop-up)
//  T  table   B  barrel   R  shelving rack (tall, blocks sight)
//  p  hostile on patrol
//  .  floor

export const MISSIONS = [
  {
    id: 'range', name: 'FIRING RANGE', sub: 'Zero in, then qualify', env: 'range', par: 0,
    brief: [
      'Free practice on steel and paper from 7 to 100 metres.',
      'Walk to the console at the firing line and press F to start the qualification drill: 20 pop-ups, 3 seconds each. Do not engage the no-shoot (civilian) targets.',
      'Bullets travel at real velocity with real gravity. Rifle rounds barely drop at 100 m. The pistol and SMG drop a little more. Listen for the steel ring: sound takes time to come back from far targets.',
    ],
    tips: ['Hold your breath for a steady aim: hold SHIFT while aiming down sights.', 'Short bursts beat full auto past 25 m.'],
  },
  {
    id: 'kh1', name: 'KILL HOUSE 1', sub: 'Fundamentals', env: 'day', par: 75, yaw: -90,
    brief: [
      'Four rooms off a central hallway. Clear every room and neutralise all hostile targets.',
      'Hostiles are OPFOR role-players with marking rounds. They turn toward you, raise their weapon, then fire. A raised weapon is your warning.',
      'TECHNIQUE: Slice the pie. Before entering, lean (Q / E) around the door frame and clear the room a slice at a time from outside. Expose yourself to one target at a time, not all of them.',
      'TECHNIQUE: Check your corners. The most dangerous spot in any room is the corner right beside the door you came in through.',
    ],
    tips: ['Lean with Q / E to slice the pie around doorways.', 'Identify before you shoot: hostiles hold a weapon, civilians do not.', 'Wooden doors do not stop bullets. Yours go through them.'],
    map: [
      '############################',
      '#.......#........#...RR....#',
      '#.h..TT.#.TT..H..#.h.....c.#',
      '#.......#.....X..D...TT....#',
      '#.......D........#.........#',
      '#B......#..c....R#.........#',
      '#.......#.......R#B.......H#',
      '####D########D########D#####',
      '#.........................H#',
      '#.P.....X..........XB......#',
      '#..........................#',
      '############################',
    ],
  },
  {
    id: 'kh2', name: 'KILL HOUSE 2', sub: 'Flash & Clear', env: 'overcast', par: 150, yaw: -90,
    brief: [
      'Six rooms, locked doors and mixed targets. Twelve hostiles (one on patrol), five no-shoots.',
      'Locked doors (red handle) must be kicked (V) or breached with a shotgun round to the lock.',
      'TECHNIQUE: Flash then enter. Open the door, throw a flashbang (G) into the room, and go in right after it pops. Stunned hostiles cannot engage you for a few seconds.',
      'TECHNIQUE: Use the windows. A window lets you clear part of a room before you ever go through the door.',
    ],
    tips: ['Open the door, then press G to throw a flashbang in. Look away!', 'Locked door? V to kick, or put a shotgun round into the lock.'],
    map: [
      '################################',
      '#..h..TT..#.RR......#.....h....#',
      '#.........#....h....#.......B..#',
      '#....c....W.........K....XX....#',
      '#.....B...#...TT....#..........#',
      '#H........#..c.....H#.......c..#',
      '######D#######K##########D######',
      '#..............................#',
      '#.P.........X.........X........#',
      '#..............................#',
      '#######D########D########D######',
      '#.RRR.......#......TT.#.B......#',
      '#..h........#....c....#..H.....#',
      '#.......XX..W.........#......h.#',
      '#...........#..H......K........#',
      '#......c....#.......h.#....H...#',
      '#.....p.....#.........#...TT...#',
      '################################',
    ],
  },
  {
    id: 'wh', name: 'WAREHOUSE', sub: 'Night Raid · Hostage Rescue', env: 'night', par: 240, yaw: 0, objective: 'hostage', mainArea: 'WAREHOUSE FLOOR',
    brief: [
      'Night. Eleven hostiles hold a warehouse with three offices. One hostage is held in the north-west office.',
      'Rescue the hostage (walk up and press F once the office is clear), then reach extraction (green marker).',
      'TECHNIQUE: Light discipline. Your weapon light (T) blinds what it hits but gives away your position. With it on, hostiles spot you from much further away. Use it in bursts.',
      'TECHNIQUE: Use cover. Crates block line of sight. Move cover to cover, crouch (C) behind them, and lean out to engage.',
    ],
    tips: ['T toggles the weapon light. Hostiles see you from further away when it is on.', 'Crouch (C) behind crates and lean out to engage.'],
    map: [
      '####################################',
      '#....TT.....#..RRR.....#...........#',
      '#..h.....S..#....h.....#...L.......#',
      '#...........K..........D.......h...#',
      '#....c......#..........#....TT.....#',
      '#...........#....XX....####D########',
      '######D######..........#...........#',
      '#...........#####D######...........#',
      '#..L..........p....................#',
      '#........XX......XXX.......XX..h...#',
      '#..XX....XX..h...XXX.......XX......#',
      '#..XX...........................H..#',
      '#..........L..........X............#',
      '#.....h...RRRR.....h..X.......L....#',
      '#.........XXXX..........XXX........#',
      '#..H......................X...h....#',
      '#...........XX....BB.............XX#',
      '#...L.......XX.......L.........E...#',
      '#.P................................#',
      '####################################',
    ],
  },
  {
    id: 'cp', name: 'COMPOUND', sub: 'Dusk Raid · Hostage Rescue', env: 'dusk', par: 300, yaw: -90, objective: 'hostage', mainArea: 'COURTYARD',
    brief: [
      'Last light. A walled compound with a six-room building in the middle. Thirteen hostiles, two of them on patrol in the courtyard.',
      'The hostage is in the large south room. Rescue them (F), then reach extraction in the south-east corner.',
      'TECHNIQUE: Watch the patrols. Guards walk a fixed route. Wait for a guard to turn their back, then move or take the shot. A hostile facing away needs time to turn before they can engage.',
      'TECHNIQUE: Pick your entry. The building has four outside doors and four windows. You do not have to use the front door.',
    ],
    tips: ['Patrolling guards turn around at the end of their route. Hit them when their back is turned.', 'Gunfire gives away your position: every hostile nearby turns toward the sound.'],
    map: [
      '########################################',
      '#......................................#',
      '#.P.......XX............B..............#',
      '#.........XX.....................XX....#',
      '#....................p.................#',
      '#...B..............................B...#',
      '#......#####D######W######D#####.......#',
      '#......#.......#.........#.....#..XX...#',
      '#..XX..#..h....#....h....#..c..#..XX...#',
      '#..XX..#...L...D....L....K.....W.......#',
      '#......#.TT....#...TTT...#.....#.......#',
      '#......W.......#.......h.#..H..#...h...#',
      '#......#....c..#..c......#.....D.......#',
      '#......###D#####K###########D###.......#',
      '#......#.......#...........#...#.......#',
      '#..H...#..H....#.....S.....#.h.#..B....#',
      '#......#.......K.....L.....D...#.......#',
      '#......D....RR.#..h....h...#...#...XX..#',
      '#......#.......#...........#..B#...XX..#',
      '#......#########W###########D###.......#',
      '#......................................#',
      '#....XX.......p...........B......H..E..#',
      '#......................................#',
      '########################################',
    ],
  },
];

export const DIFFICULTY = {
  recruit: { name: 'RECRUIT', react: 2.2, hit: 0.55, detect: 1.0, turn: 2.2 },
  operator: { name: 'OPERATOR', react: 1.4, hit: 0.75, detect: 1.0, turn: 3.2 },
  elite: { name: 'ELITE', react: 0.85, hit: 0.9, detect: 1.2, turn: 4.6 },
};
