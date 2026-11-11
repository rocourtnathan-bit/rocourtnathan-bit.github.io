// Mission definitions. Grid maps: 1 char = 1 m.
//  #  wall          D  door            K  locked door (kick / shotgun breach)
//  W  window        X  crate (cover)   L  hanging lamp
//  P  spawn         E  extraction      S  hostage
//  h  hostile (standing)   H  hostile (pop-up, rises when you get close)
//  c  civilian (standing)  C  civilian (pop-up)
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
      'Hostiles carry MILES laser emitters. Stay exposed in their line of sight too long and they will tag you.',
      'TECHNIQUE: Slice the pie. Before entering, lean (Q / E) around the door frame and clear the room a slice at a time from outside. Expose yourself to one target at a time, not all of them.',
      'TECHNIQUE: Check your corners. The most dangerous spot in any room is the corner right beside the door you came in through.',
    ],
    tips: ['Lean with Q / E to slice the pie around doorways.', 'Identify before you shoot: hostiles hold a weapon, civilians do not.'],
    map: [
      '############################',
      '#.......#........#.........#',
      '#.h.....#.....H..#.h.....c.#',
      '#.......#........D.........#',
      '#.......D........#.........#',
      '#.......#..c.....#.........#',
      '#.......#........#........H#',
      '####D########D########D#####',
      '#.........................H#',
      '#.P.....X..........X.......#',
      '#..........................#',
      '############################',
    ],
  },
  {
    id: 'kh2', name: 'KILL HOUSE 2', sub: 'Flash & Clear', env: 'overcast', par: 150, yaw: -90,
    brief: [
      'Six rooms, locked doors and mixed targets. Eleven hostiles, five no-shoots.',
      'Locked doors (red handle) must be kicked (V) or breached with a shotgun round to the lock.',
      'TECHNIQUE: Flash then enter. Open the door, throw a flashbang (G) into the room, and go in right after it pops. Stunned hostiles cannot engage you for a few seconds.',
      'TECHNIQUE: Use the windows. A window lets you clear part of a room before you ever go through the door.',
    ],
    tips: ['Open the door, then press G to throw a flashbang in. Look away!', 'Locked door? V to kick, or put a shotgun round into the lock.'],
    map: [
      '################################',
      '#..h......#.........#.....h....#',
      '#.........#....h....#..........#',
      '#....c....W.........K....XX....#',
      '#.........#.........#..........#',
      '#H........#..c.....H#.......c..#',
      '######D#######K##########D######',
      '#..............................#',
      '#.P.........X.........X........#',
      '#..............................#',
      '#######D########D########D######',
      '#...........#.........#........#',
      '#..h........#....c....#..H.....#',
      '#.......XX..W.........#......h.#',
      '#...........#..H......K........#',
      '#......c....#.......h.#....H...#',
      '#...........#.........#........#',
      '################################',
    ],
  },
  {
    id: 'wh', name: 'WAREHOUSE', sub: 'Night Raid · Hostage Rescue', env: 'night', par: 240, yaw: 0, objective: 'hostage', mainArea: 'WAREHOUSE FLOOR',
    brief: [
      'Night. Ten hostiles hold a warehouse with three offices. One hostage is held in the north-west office.',
      'Rescue the hostage (walk up and press F once the office is clear), then reach extraction (green marker).',
      'TECHNIQUE: Light discipline. Your weapon light (T) blinds what it hits but gives away your position. With it on, hostiles spot you from much further away. Use it in bursts.',
      'TECHNIQUE: Use cover. Crates block line of sight. Move cover to cover, crouch (C) behind them, and lean out to engage.',
    ],
    tips: ['T toggles the weapon light. Hostiles see you from further away when it is on.', 'Crouch (C) behind crates and lean out to engage.'],
    map: [
      '####################################',
      '#...........#..........#...........#',
      '#..h.....S..#....h.....#...L.......#',
      '#...........K..........D.......h...#',
      '#....c......#..........#...........#',
      '#...........#....XX....####D########',
      '######D######..........#...........#',
      '#...........#####D######...........#',
      '#..L...............................#',
      '#........XX......XXX.......XX..h...#',
      '#..XX....XX..h...XXX.......XX......#',
      '#..XX...........................H..#',
      '#..........L..........X............#',
      '#.....h...XXXX.....h..X.......L....#',
      '#.........XXXX..........XXX........#',
      '#..H......................X...h....#',
      '#...........XX...................XX#',
      '#...L.......XX.......L.........E...#',
      '#.P................................#',
      '####################################',
    ],
  },
];

export const DIFFICULTY = {
  recruit: { name: 'RECRUIT', react: 2.2, hit: 0.55, detect: 1.0 },
  operator: { name: 'OPERATOR', react: 1.4, hit: 0.75, detect: 1.0 },
  elite: { name: 'ELITE', react: 0.85, hit: 0.9, detect: 1.2 },
};
