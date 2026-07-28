class_name ClassicStockMonsterIconCatalog
extends RefCounted

# Stock monster cicn IDs are not monster IDs: authored records may reuse the
# same picture for unrelated creatures. These mappings were verified against
# the Realmz Family Jewels resource fork by comparing decoded visible pixels
# and masks with the shared bestiary atlas. Aliases are atlas keys with
# identical source pixels.
const IMAGE_KEYS_BY_ICON_ID := {
	384: ["CREA_goblin"],
	385: ["CREA_orc_shaman"],
	386: ["CREA_classic_cicn_386"],
	387: ["CREA_goblin_hero"],
	388: ["CREA_goblin_archer"],
	389: ["CREA_goblin_chief"],
	390: ["CREA_goblin_champion"],
	391: ["CREA_giant_bee"],
	392: ["CREA_giant_frog"],
	393: ["CREA_giant_centipede"],
	394: ["CREA_cave_lizard"],
	395: ["CREA_dogre"],
	396: ["CREA_dinosaur5"],
	397: ["CREA_gnath"],
	398: ["CREA_carrion_slug", "CREA_larva", "CREA_slime_worm"],
	399: ["CREA_whip_scorpion"],
	400: ["CREA_kisk_dragon"],
	401: ["CREA_giant_wyrm"],
	402: ["CREA_rock_spider"],
	403: ["CREA_dune_spider"],
	404: ["CREA_classic_cicn_404"],
	405: ["CREA_hell_dragon"],
	406: ["CREA_minotaur1", "CREA_minotaur2"],
	407: ["CREA_classic_cicn_407"],
	408: ["CREA_troll"],
	409: ["CREA_skeletal_beast"],
	410: ["CREA_horvath"],
	411: ["CREA_skeletal_giant"],
	412: ["CREA_proto_shantile"],
	413: ["CREA_silt_spider"],
	414: ["CREA_vesp_spider"],
	415: ["CREA_proto_vrack"],
	416: ["CREA_proto_hyena"],
	417: ["CREA_apprentice"],
	418: ["CREA_dinosaur1"],
	419: ["CREA_classic_cicn_419"],
	420: ["CREA_dragon_lizard", "CREA_terror_beast"],
	421: ["CREA_classic_cicn_421"],
	422: ["CREA_classic_cicn_422"],
	423: ["CREA_vixies_spider"],
	424: ["CREA_guardian_spider"],
	425: ["CREA_giant_snake"],
	426: ["CREA_dinosaur2"],
	427: ["CREA_classic_cicn_427"],
	428: ["CREA_sabre_feline"],
	429: ["CREA_classic_cicn_429"],
	430: ["CREA_red_dragon"],
	431: ["CREA_blue_dragon"],
	432: ["CREA_green_dragon"],
	433: ["CREA_classic_cicn_433"],
	434: ["CREA_rat_demilord"],
	435: ["CREA_spectre"],
	436: ["CREA_giant_zombie"],
	437: ["CREA_gnome_warrior"],
	438: ["CREA_dogre_champion"],
	439: ["CREA_proto_badger"],
	440: ["CREA_hill_giant", "CREA_young_hill_giant"],
	441: ["CREA_cavalry_trooper"],
	442: ["CREA_cavalry_officer"],
	443: ["CREA_dinosaur3"],
	444: ["CREA_demon_lord", "CREA_minor_demon"],
	445: ["CREA_ogre"],
	446: ["CREA_dinosaur4"],
	447: ["CREA_classic_cicn_447"],
	448: ["CREA_classic_cicn_448"],
	449: ["CREA_giant_rat"],
	450: ["CREA_cacodaemon_warlord"],
	451: ["CREA_hell_bat"],
	452: ["CREA_dinosaur6"],
	453: ["CREA_classic_cicn_453"],
	454: ["CREA_rewop"],
	455: ["CREA_winged_devil"],
	456: ["CREA_mush_mound"],
	457: ["CREA_mummy"],
	458: ["CREA_mush_man", "CREA_podling"],
	459: ["CREA_classic_cicn_459"],
	460: ["CREA_hag"],
	461: ["CREA_flesh_fiend"],
	464: ["CREA_slimeY"],
	465: ["CREA_slimeG", "CREA_small_slime"],
	466: ["CREA_humanmage"],
	467: ["CREA_ghoul"],
	468: ["CREA_giant_spider"],
	469: ["CREA_classic_cicn_469"],
	470: ["CREA_zombie"],
	472: ["CREA_classic_cicn_472"],
	473: ["CREA_giant_boar"],
	475: ["CREA_antiid", "CREA_slime_demon"],
	478: ["CREA_fire_fiend"],
	481: ["CREA_classic_cicn_481"],
	482: ["CREA_trigwig"],
	483: ["CREA_classic_cicn_483"],
	485: ["CREA_classic_cicn_485"],
	486: ["CREA_royal_guard"],
	487: ["CREA_royal_corporal"],
	488: ["CREA_royal_sergeant"],
	489: ["CREA_royal_lieutenant"],
	490: ["CREA_royal_captain"],
	491: ["CREA_classic_cicn_491"],
	492: ["CREA_dwarfwarrior"],
	493: ["CREA_classic_cicn_493"],
	494: ["CREA_krise"],
	495: ["CREA_thief"],
	496: ["CREA_mercenary_villain"],
	500: ["CREA_demon"],
	501: ["CREA_giant_wasp"],
	502: ["CREA_shantile", "CREA_troglodyte"],
	503: ["CREA_classic_cicn_503"],
	504: ["CREA_young_troll"],
	505: ["CREA_skeletal_warrior"],
	506: ["CREA_mental_flea"],
	507: ["CREA_beetle"],
	508: ["CREA_goblin_shaman"],
	509: ["CREA_classic_cicn_509"],
	510: ["CREA_giant_scorpion"],
	511: ["CREA_monstrous_rat"],
	512: ["CREA_orc_champion", "CREA_orc_warrior2"],
	513: ["CREA_orc_archer"],
	514: ["CREA_beast_man"],
	515: ["CREA_orc_warrior"],
	516: ["CREA_giant_worker_ant"],
}

# Icon 436's shared atlas image is the exact paired-facing cicn 744. All other
# preferred keys above match the base cicn itself.
const PAIRED_SOURCE_ICON_IDS := {436: 744}


static func image_key(icon_id: int) -> String:
	var keys: Variant = IMAGE_KEYS_BY_ICON_ID.get(icon_id, [])
	if not (keys is Array) or keys.is_empty():
		return ""
	return str(keys[0])


static func image_aliases(icon_id: int) -> Array:
	var keys: Variant = IMAGE_KEYS_BY_ICON_ID.get(icon_id, [])
	return keys.duplicate() if keys is Array else []


static func supported_icon_ids() -> Array:
	var ids: Array = IMAGE_KEYS_BY_ICON_ID.keys()
	ids.sort()
	return ids
