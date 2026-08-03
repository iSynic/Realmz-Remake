import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, "..");
const defaultOutputPath = path.resolve(
  repositoryRoot,
  "src",
  "scripts",
  "classic_runtime",
  "data",
  "standard_character_rules.json",
);

if (!process.argv[2]) {
  throw new Error(
    "Usage: node tools/generate_standard_character_rules.mjs "
      + "<realmzMetadata.json> [output.json]",
  );
}

const metadataPath = path.resolve(process.argv[2]);
const outputPath = path.resolve(process.argv[3] ?? defaultOutputPath);
const metadataBytes = fs.readFileSync(metadataPath);
const metadata = JSON.parse(metadataBytes.toString("utf8"));

const STANDARD_RACE_COUNT = 19;
const STANDARD_CASTE_COUNT = 20;

function requireArray(value, expectedLength, fieldName) {
  if (!Array.isArray(value) || value.length !== expectedLength) {
    throw new Error(`${fieldName} must contain ${expectedLength} entries.`);
  }
  return value;
}

function integerFlags(values) {
  return values.map((value) => (value ? 1 : 0));
}

function mapRace(profile) {
  return {
    id: profile.id - 1,
    displayName: profile.name,
    plusMinusToHit: profile.plusMinusToHit,
    // Realmz stores one reserved fifteenth slot after the fourteen skills used
    // by creation, display, and level-up code.
    specialAbility: profile.specialAbility.slice(0, 14),
    drvBonus: profile.saveBonuses,
    attBonus: profile.attributeBonuses,
    minMax: profile.minMax,
    conditions: profile.conditions,
    maxAge: profile.maxAge,
    doesNotDie: profile.doesNotDie,
    baseMove: profile.baseMove,
    magRes: profile.magres,
    twoHand: profile.twohand,
    missile: profile.missile,
    numOfAttacks: profile.numOfAttacks,
    canCaste: integerFlags(profile.casteAllowed),
    ageRange: profile.ageRanges,
    ageChange: profile.ageChanges,
    canRegenerate: profile.canRegenerate ? 1 : 0,
    defaultIconSet: profile.defaultIconSet,
    itemTypes: profile.itemtypes,
    descriptors: profile.descriptors,
    authored: true,
  };
}

function mapCaste(profile) {
  return {
    id: profile.id - 1,
    displayName: profile.name,
    specialAbility: [
      profile.specialAbilityBase.slice(0, 14),
      profile.specialAbilityLevelGains.slice(0, 14),
    ],
    drvBonus: profile.saveBonuses,
    attBonus: profile.attributeBonuses,
    spellcasters: profile.spellcasters,
    minMax: profile.minMax,
    conditions: profile.conditions,
    canUseMissile: profile.canUseMissile ? 1 : 0,
    getsMissileBonus: profile.getsMissileBonus ? 1 : 0,
    stamina: profile.stamina,
    strength: profile.strength,
    dodge: profile.dodge,
    toHit: profile.tohit,
    missile: profile.missile,
    hand2Hand: profile.hand2hand,
    casteClass: profile.casteClass,
    minimumAgeGroup: profile.minimumAgeGroup,
    moveBonus: profile.moveBonus,
    magRes: profile.magres,
    twoHand: profile.twohand,
    maxStaminaBonus: profile.maxStaminaBonus,
    bonusAttacks: profile.bonusAttacks,
    maxAttacks: profile.maxAttacks,
    victory: profile.victory,
    startMoney: profile.startMoney,
    startItems: profile.startItems,
    attacks: profile.attacks,
    itemTypes: profile.itemtypes,
    defaultIcon: profile.defaultIcon,
    maxSpellsAttacks: profile.maxSpellsAttacks,
    spellsSoFar: profile.spellsSoFar,
    authored: true,
  };
}

const raceProfiles = requireArray(
  metadata.raceProfiles,
  30,
  "raceProfiles",
).slice(0, STANDARD_RACE_COUNT);
const casteProfiles = requireArray(
  metadata.casteProfiles,
  30,
  "casteProfiles",
).slice(0, STANDARD_CASTE_COUNT);

for (const [index, profile] of raceProfiles.entries()) {
  if (profile.id !== index + 1 || !profile.name) {
    throw new Error(`Unexpected standard race metadata at index ${index}.`);
  }
  requireArray(profile.casteAllowed, 30, `${profile.name}.casteAllowed`);
}
for (const [index, profile] of casteProfiles.entries()) {
  if (profile.id !== index + 1 || !profile.name) {
    throw new Error(`Unexpected standard caste metadata at index ${index}.`);
  }
  requireArray(profile.victory, 30, `${profile.name}.victory`);
  requireArray(profile.startItems, 20, `${profile.name}.startItems`);
}

const raceOverrides = raceProfiles.map(mapRace);
const casteOverrides = casteProfiles.map(mapCaste);
const result = {
  schemaVersion: 1,
  provenance: {
    description:
      "Standard Realmz character rules derived from the source-backed Character Editor metadata extractor.",
    authoritativeSources: [
      "newcharacter.c",
      "levelup.c",
      "misc.c",
      "convert.c",
      "showitems-showspecial.c",
      "structs.h",
    ],
    metadataSha256: crypto
      .createHash("sha256")
      .update(metadataBytes)
      .digest("hex"),
  },
  ruleNames: {
    authored: true,
    raceNames: raceProfiles.map((profile) => profile.name),
    casteNames: casteProfiles.map((profile) => profile.name),
  },
  tableSelection: {
    races: {
      source: "scenario-local",
      changedRecordIds: raceOverrides.map((record) => record.id),
    },
    castes: {
      source: "scenario-local",
      changedRecordIds: casteOverrides.map((record) => record.id),
    },
  },
  raceOverrides,
  casteOverrides,
};

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
console.log(`Wrote ${outputPath}`);
