  ---
-- DNC JOB PROFILE
-- Loaded by Lazy.lua into JOB_PROFILES.DNC.
-- DNCQUEEN handles DNC-specific rotation logic.
  -------------

JOB_PROFILES.DNC = {
    auto_engage = true,
    use_weaponskills = true,
    haste_active = false,

      
    -- SELF BUFFS
      
    self_buffs = {},

      
    -- WEAPONSKILLS
      
    ws_sc_starter = {
        "Rudra's Storm",
        2000,
    },

    ws_sc_closers = {
        "Rudra's Storm",
    },

      
    -- DNC ROTATION
      
    dnc_rotation = true,

      
    -- DNC JOB ABILITIES
      
    dnc_abilities = {
        'Trance',
        'Contradance',
        'Saber Dance',
        'Fan Dance',
        'No Foot Rise',
        'Presto',
        'Grand Pas',

        'Haste Samba',

        'Box Step',
        'Reverse Flourish',
        'Climactic Flourish',
        'Violent Flourish',

        'Curing Waltz',
        'Curing Waltz II',
        'Curing Waltz III',
        'Curing Waltz IV',
        'Curing Waltz V',
    },

      
    -- SAMBA
      
    dnc_sambas = {
        'Haste Samba',
    },

      
    -- STEPS
      
    dnc_steps = {
        'Box Step',
    },

      
    -- FLOURISHES
      
    dnc_flourishes = {
        'Reverse Flourish',
        'Climactic Flourish',
        'Violent Flourish',
    },

      
    -- FOOD
      
    food = 'Soy Ramen',
}
