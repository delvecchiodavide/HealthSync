import Foundation
import HealthKit

/// How a metric is read from HealthKit and which value columns it produces.
public enum MetricKind: Sendable, Hashable {
    /// A quantity type read in `unit` (an `HKUnit(from:)` string).
    case quantity(identifier: String, unit: String)
    /// A category type whose value is its duration in minutes (e.g. mindful sessions).
    case category(identifier: String)
    /// A category type whose value is a coded state (symptom severity, test result, …).
    case categoryEvent(identifier: String, values: CategoryValueSet)
    case sleep
    case workout
    case bloodPressure

    /// Kind-specific columns, placed between the common leading and trailing columns.
    public var valueColumns: [String] {
        switch self {
        case .quantity, .category: ["value", "unit"]
        case .categoryEvent: ["value", "duration_min"]
        case .sleep: ["sleep_stage", "value", "unit"]
        case .workout: ["activity_type", "duration_min", "energy_kcal", "distance_km", "avg_heart_rate_bpm"]
        case .bloodPressure: ["systolic_mmHg", "diastolic_mmHg"]
        }
    }
}

/// The set of coded values a category type uses, so they're written as readable labels.
public enum CategoryValueSet: Sendable, Hashable {
    case event, severity, presence, menstrualFlow, ovulationTest, cervicalMucus, appetite,
         contraceptive, testResult, standHour, walkingSteadiness, lowCardioFitness, limitExceeded

    public func label(for value: Int) -> String {
        let labels: [Int: String] = switch self {
        case .event: [0: "event"]
        case .severity: [0: "unspecified", 1: "not_present", 2: "mild", 3: "moderate", 4: "severe"]
        case .presence: [0: "present", 1: "not_present"]
        case .menstrualFlow: [1: "unspecified", 2: "light", 3: "medium", 4: "heavy", 5: "none"]
        case .ovulationTest: [1: "negative", 2: "lh_surge", 3: "indeterminate", 4: "estrogen_surge"]
        case .cervicalMucus: [1: "dry", 2: "sticky", 3: "creamy", 4: "watery", 5: "egg_white"]
        case .appetite: [0: "unspecified", 1: "no_change", 2: "decreased", 3: "increased"]
        case .contraceptive: [1: "unspecified", 2: "implant", 3: "injection", 4: "iud", 5: "intravaginal_ring", 6: "oral", 7: "patch"]
        case .testResult: [1: "negative", 2: "positive", 3: "indeterminate"]
        case .standHour: [0: "stood", 1: "idle"]
        case .walkingSteadiness: [1: "initial_low", 2: "initial_very_low", 3: "repeat_low", 4: "repeat_very_low"]
        case .lowCardioFitness: [1: "low_fitness"]
        case .limitExceeded: [1: "limit_exceeded"]
        }
        return labels[value] ?? "value_\(value)"
    }
}

/// Groups shown in the data type picker.
public enum MetricCategory: String, Sendable, Hashable, CaseIterable, Identifiable {
    case activity, heart, body, vitals, respiratory, nutrition, sleepMindfulness, hearing, reproductive, symptoms, other
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .activity: "Activity"
        case .heart: "Heart"
        case .body: "Body Measurements"
        case .vitals: "Vitals"
        case .respiratory: "Respiratory"
        case .nutrition: "Nutrition"
        case .sleepMindfulness: "Sleep & Mindfulness"
        case .hearing: "Hearing"
        case .reproductive: "Cycle Tracking & Reproductive Health"
        case .symptoms: "Symptoms"
        case .other: "Other Data"
        }
    }

    public var symbol: String {
        switch self {
        case .activity: "flame.fill"
        case .heart: "heart.fill"
        case .body: "figure"
        case .vitals: "waveform.path.ecg"
        case .respiratory: "lungs.fill"
        case .nutrition: "fork.knife"
        case .sleepMindfulness: "bed.double.fill"
        case .hearing: "ear.fill"
        case .reproductive: "circle.dotted.circle"
        case .symptoms: "list.bullet.clipboard.fill"
        case .other: "plus.square.fill"
        }
    }

    public var metrics: [HealthMetric] {
        HealthMetric.all.filter { $0.category == self }
    }
}

/// A Health data type that can be synced to its own spreadsheet.
public struct HealthMetric: Sendable, Hashable, Identifiable {
    /// Stable key used for persistence. Never change it once shipped.
    public let id: String
    public let displayName: String
    public let kind: MetricKind
    public let category: MetricCategory
    public let defaultEnabled: Bool

    public init(id: String, displayName: String, kind: MetricKind, category: MetricCategory, defaultEnabled: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.category = category
        self.defaultEnabled = defaultEnabled
    }

    public static let commonLeadingColumns = ["uuid", "start_date", "end_date"]
    public static let commonTrailingColumns = ["source_name", "source_bundle_id", "device", "timezone", "synced_at", "deleted"]

    public var sheetName: String { "HealthSync - \(displayName)" }
    public var columns: [String] { Self.commonLeadingColumns + kind.valueColumns + Self.commonTrailingColumns }
    /// Zero-based index of the `deleted` column (always last).
    public var deletedColumnIndex: Int { columns.count - 1 }
}

// MARK: - Registry

extension HealthMetric {
    /// Every supported metric. Adding a new type is one line here.
    public static let all: [HealthMetric] = activity + heart + body + vitals + respiratory + nutrition
        + sleepMindfulness + hearing + reproductive + symptoms + other

    public static let defaultEnabledIDs: Set<String> = Set(all.filter(\.defaultEnabled).map(\.id))

    public static func metric(id: String) -> HealthMetric? {
        all.first { $0.id == id }
    }

    private static let activity: [HealthMetric] = [
        q("steps", "Steps", .stepCount, "count", .activity, on: true),
        q("walking_running_distance", "Walking + Running Distance", .distanceWalkingRunning, "km", .activity, on: true),
        q("active_energy", "Active Energy", .activeEnergyBurned, "kcal", .activity, on: true),
        q("resting_energy", "Resting Energy", .basalEnergyBurned, "kcal", .activity, on: true),
        HealthMetric(id: "workouts", displayName: "Workouts", kind: .workout, category: .activity, defaultEnabled: true),
        q("flights_climbed", "Flights Climbed", .flightsClimbed, "count", .activity),
        q("exercise_time", "Exercise Minutes", .appleExerciseTime, "min", .activity),
        q("move_time", "Move Minutes", .appleMoveTime, "min", .activity),
        q("stand_time", "Stand Minutes", .appleStandTime, "min", .activity),
        e("stand_hours", "Stand Hours", .appleStandHour, .standHour, .activity),
        q("cycling_distance", "Cycling Distance", .distanceCycling, "km", .activity),
        q("swimming_distance", "Swimming Distance", .distanceSwimming, "m", .activity),
        q("swimming_strokes", "Swimming Strokes", .swimmingStrokeCount, "count", .activity),
        q("wheelchair_distance", "Wheelchair Distance", .distanceWheelchair, "km", .activity),
        q("wheelchair_pushes", "Wheelchair Pushes", .pushCount, "count", .activity),
        q("snow_sports_distance", "Downhill Snow Sports Distance", .distanceDownhillSnowSports, "km", .activity),
        q("walking_speed", "Walking Speed", .walkingSpeed, "km/hr", .activity),
        q("walking_step_length", "Walking Step Length", .walkingStepLength, "cm", .activity),
        q("walking_double_support", "Double Support Time", .walkingDoubleSupportPercentage, "%", .activity),
        q("walking_asymmetry", "Walking Asymmetry", .walkingAsymmetryPercentage, "%", .activity),
        q("walking_steadiness", "Walking Steadiness", .appleWalkingSteadiness, "%", .activity),
        e("walking_steadiness_events", "Walking Steadiness Notifications", .appleWalkingSteadinessEvent, .walkingSteadiness, .activity),
        q("six_minute_walk", "Six-Minute Walk Distance", .sixMinuteWalkTestDistance, "m", .activity),
        q("stair_ascent_speed", "Stair Speed: Up", .stairAscentSpeed, "m/s", .activity),
        q("stair_descent_speed", "Stair Speed: Down", .stairDescentSpeed, "m/s", .activity),
        q("running_speed", "Running Speed", .runningSpeed, "km/hr", .activity),
        q("running_power", "Running Power", .runningPower, "W", .activity),
        q("running_stride_length", "Running Stride Length", .runningStrideLength, "m", .activity),
        q("running_vertical_oscillation", "Vertical Oscillation", .runningVerticalOscillation, "cm", .activity),
        q("running_ground_contact", "Ground Contact Time", .runningGroundContactTime, "ms", .activity),
        q("cycling_speed", "Cycling Speed", .cyclingSpeed, "km/hr", .activity),
        q("cycling_power", "Cycling Power", .cyclingPower, "W", .activity),
        q("cycling_cadence", "Cycling Cadence", .cyclingCadence, "count/min", .activity),
        q("cycling_ftp", "Cycling Functional Threshold Power", .cyclingFunctionalThresholdPower, "W", .activity),
        q("physical_effort", "Physical Effort", .physicalEffort, "kcal/(kg*hr)", .activity),
        q("vo2_max", "Cardio Fitness (VO2 Max)", .vo2Max, "ml/kg*min", .activity),
    ]

    private static let heart: [HealthMetric] = [
        q("heart_rate", "Heart Rate", .heartRate, "count/min", .heart, on: true),
        q("resting_heart_rate", "Resting Heart Rate", .restingHeartRate, "count/min", .heart, on: true),
        q("hrv", "Heart Rate Variability", .heartRateVariabilitySDNN, "ms", .heart, on: true),
        q("walking_heart_rate", "Walking Heart Rate Average", .walkingHeartRateAverage, "count/min", .heart),
        q("heart_rate_recovery", "Cardio Recovery", .heartRateRecoveryOneMinute, "count/min", .heart),
        q("afib_burden", "AFib History", .atrialFibrillationBurden, "%", .heart),
        q("peripheral_perfusion", "Peripheral Perfusion Index", .peripheralPerfusionIndex, "%", .heart),
        e("high_heart_rate_events", "High Heart Rate Notifications", .highHeartRateEvent, .event, .heart),
        e("low_heart_rate_events", "Low Heart Rate Notifications", .lowHeartRateEvent, .event, .heart),
        e("irregular_rhythm_events", "Irregular Rhythm Notifications", .irregularHeartRhythmEvent, .event, .heart),
        e("low_cardio_fitness_events", "Low Cardio Fitness Notifications", .lowCardioFitnessEvent, .lowCardioFitness, .heart),
    ]

    private static let body: [HealthMetric] = [
        q("body_mass", "Weight", .bodyMass, "kg", .body, on: true),
        q("height", "Height", .height, "cm", .body),
        q("bmi", "Body Mass Index", .bodyMassIndex, "count", .body),
        q("body_fat", "Body Fat Percentage", .bodyFatPercentage, "%", .body),
        q("lean_body_mass", "Lean Body Mass", .leanBodyMass, "kg", .body),
        q("waist_circumference", "Waist Circumference", .waistCircumference, "cm", .body),
    ]

    private static let vitals: [HealthMetric] = [
        HealthMetric(id: "blood_pressure", displayName: "Blood Pressure", kind: .bloodPressure, category: .vitals),
        q("blood_oxygen", "Blood Oxygen", .oxygenSaturation, "%", .vitals),
        q("body_temperature", "Body Temperature", .bodyTemperature, "degC", .vitals),
        q("basal_body_temperature", "Basal Body Temperature", .basalBodyTemperature, "degC", .vitals),
        q("wrist_temperature", "Sleeping Wrist Temperature", .appleSleepingWristTemperature, "degC", .vitals),
        q("blood_glucose", "Blood Glucose", .bloodGlucose, "mg/dL", .vitals),
        q("electrodermal_activity", "Electrodermal Activity", .electrodermalActivity, "mcS", .vitals),
    ]

    private static let respiratory: [HealthMetric] = [
        q("respiratory_rate", "Respiratory Rate", .respiratoryRate, "count/min", .respiratory),
        q("forced_vital_capacity", "Forced Vital Capacity", .forcedVitalCapacity, "L", .respiratory),
        q("forced_expiratory_volume", "Forced Expiratory Volume, 1 sec", .forcedExpiratoryVolume1, "L", .respiratory),
        q("peak_expiratory_flow", "Peak Expiratory Flow Rate", .peakExpiratoryFlowRate, "L/min", .respiratory),
        q("inhaler_usage", "Inhaler Usage", .inhalerUsage, "count", .respiratory),
    ]

    private static let nutrition: [HealthMetric] = [
        q("dietary_energy", "Dietary Energy", .dietaryEnergyConsumed, "kcal", .nutrition, on: true),
        q("water", "Water", .dietaryWater, "mL", .nutrition, on: true),
        q("protein", "Protein", .dietaryProtein, "g", .nutrition),
        q("carbohydrates", "Carbohydrates", .dietaryCarbohydrates, "g", .nutrition),
        q("fat_total", "Total Fat", .dietaryFatTotal, "g", .nutrition),
        q("fat_saturated", "Saturated Fat", .dietaryFatSaturated, "g", .nutrition),
        q("fat_monounsaturated", "Monounsaturated Fat", .dietaryFatMonounsaturated, "g", .nutrition),
        q("fat_polyunsaturated", "Polyunsaturated Fat", .dietaryFatPolyunsaturated, "g", .nutrition),
        q("cholesterol", "Dietary Cholesterol", .dietaryCholesterol, "mg", .nutrition),
        q("sugar", "Dietary Sugar", .dietarySugar, "g", .nutrition),
        q("fiber", "Fiber", .dietaryFiber, "g", .nutrition),
        q("sodium", "Sodium", .dietarySodium, "mg", .nutrition),
        q("potassium", "Potassium", .dietaryPotassium, "mg", .nutrition),
        q("calcium", "Calcium", .dietaryCalcium, "mg", .nutrition),
        q("iron", "Iron", .dietaryIron, "mg", .nutrition),
        q("magnesium", "Magnesium", .dietaryMagnesium, "mg", .nutrition),
        q("phosphorus", "Phosphorus", .dietaryPhosphorus, "mg", .nutrition),
        q("zinc", "Zinc", .dietaryZinc, "mg", .nutrition),
        q("copper", "Copper", .dietaryCopper, "mg", .nutrition),
        q("manganese", "Manganese", .dietaryManganese, "mg", .nutrition),
        q("selenium", "Selenium", .dietarySelenium, "mcg", .nutrition),
        q("chromium", "Chromium", .dietaryChromium, "mcg", .nutrition),
        q("molybdenum", "Molybdenum", .dietaryMolybdenum, "mcg", .nutrition),
        q("iodine", "Iodine", .dietaryIodine, "mcg", .nutrition),
        q("chloride", "Chloride", .dietaryChloride, "mg", .nutrition),
        q("vitamin_a", "Vitamin A", .dietaryVitaminA, "mcg", .nutrition),
        q("vitamin_b6", "Vitamin B6", .dietaryVitaminB6, "mg", .nutrition),
        q("vitamin_b12", "Vitamin B12", .dietaryVitaminB12, "mcg", .nutrition),
        q("vitamin_c", "Vitamin C", .dietaryVitaminC, "mg", .nutrition),
        q("vitamin_d", "Vitamin D", .dietaryVitaminD, "mcg", .nutrition),
        q("vitamin_e", "Vitamin E", .dietaryVitaminE, "mg", .nutrition),
        q("vitamin_k", "Vitamin K", .dietaryVitaminK, "mcg", .nutrition),
        q("thiamin", "Thiamin (B1)", .dietaryThiamin, "mg", .nutrition),
        q("riboflavin", "Riboflavin (B2)", .dietaryRiboflavin, "mg", .nutrition),
        q("niacin", "Niacin (B3)", .dietaryNiacin, "mg", .nutrition),
        q("pantothenic_acid", "Pantothenic Acid (B5)", .dietaryPantothenicAcid, "mg", .nutrition),
        q("biotin", "Biotin (B7)", .dietaryBiotin, "mcg", .nutrition),
        q("folate", "Folate", .dietaryFolate, "mcg", .nutrition),
        q("caffeine", "Caffeine", .dietaryCaffeine, "mg", .nutrition),
        q("alcoholic_beverages", "Alcoholic Beverages", .numberOfAlcoholicBeverages, "count", .nutrition),
        q("blood_alcohol", "Blood Alcohol Content", .bloodAlcoholContent, "%", .nutrition),
    ]

    private static let sleepMindfulness: [HealthMetric] = [
        HealthMetric(id: "sleep", displayName: "Sleep", kind: .sleep, category: .sleepMindfulness, defaultEnabled: true),
        HealthMetric(id: "mindful_minutes", displayName: "Mindful Minutes",
                     kind: .category(identifier: HKCategoryTypeIdentifier.mindfulSession.rawValue), category: .sleepMindfulness),
        q("daylight", "Time in Daylight", .timeInDaylight, "min", .sleepMindfulness),
    ]

    private static let hearing: [HealthMetric] = [
        q("environmental_audio", "Environmental Sound Levels", .environmentalAudioExposure, "dBASPL", .hearing),
        q("headphone_audio", "Headphone Audio Levels", .headphoneAudioExposure, "dBASPL", .hearing),
        q("environmental_sound_reduction", "Environmental Sound Reduction", .environmentalSoundReduction, "dBASPL", .hearing),
        e("environmental_audio_events", "Noise Notifications", .environmentalAudioExposureEvent, .limitExceeded, .hearing),
        e("headphone_audio_events", "Headphone Notifications", .headphoneAudioExposureEvent, .limitExceeded, .hearing),
    ]

    private static let reproductive: [HealthMetric] = [
        e("menstrual_flow", "Menstrual Flow", .menstrualFlow, .menstrualFlow, .reproductive),
        e("intermenstrual_bleeding", "Spotting", .intermenstrualBleeding, .event, .reproductive),
        e("ovulation_test", "Ovulation Test Result", .ovulationTestResult, .ovulationTest, .reproductive),
        e("cervical_mucus", "Cervical Mucus Quality", .cervicalMucusQuality, .cervicalMucus, .reproductive),
        e("sexual_activity", "Sexual Activity", .sexualActivity, .event, .reproductive),
        e("contraceptive", "Contraceptives", .contraceptive, .contraceptive, .reproductive),
        e("pregnancy", "Pregnancy", .pregnancy, .event, .reproductive),
        e("lactation", "Lactation", .lactation, .event, .reproductive),
        e("pregnancy_test", "Pregnancy Test Result", .pregnancyTestResult, .testResult, .reproductive),
        e("progesterone_test", "Progesterone Test Result", .progesteroneTestResult, .testResult, .reproductive),
        e("infrequent_cycles", "Infrequent Periods", .infrequentMenstrualCycles, .event, .reproductive),
        e("irregular_cycles", "Irregular Cycles", .irregularMenstrualCycles, .event, .reproductive),
        e("persistent_spotting", "Persistent Spotting", .persistentIntermenstrualBleeding, .event, .reproductive),
        e("prolonged_periods", "Prolonged Periods", .prolongedMenstrualPeriods, .event, .reproductive),
    ]

    private static let symptoms: [HealthMetric] = [
        e("abdominal_cramps", "Abdominal Cramps", .abdominalCramps, .severity, .symptoms),
        e("acne", "Acne", .acne, .severity, .symptoms),
        e("appetite_changes", "Appetite Changes", .appetiteChanges, .appetite, .symptoms),
        e("bladder_incontinence", "Bladder Incontinence", .bladderIncontinence, .severity, .symptoms),
        e("bloating", "Bloating", .bloating, .severity, .symptoms),
        e("breast_pain", "Breast Pain", .breastPain, .severity, .symptoms),
        e("chest_pain", "Chest Tightness or Pain", .chestTightnessOrPain, .severity, .symptoms),
        e("chills", "Chills", .chills, .severity, .symptoms),
        e("constipation", "Constipation", .constipation, .severity, .symptoms),
        e("coughing", "Coughing", .coughing, .severity, .symptoms),
        e("diarrhea", "Diarrhea", .diarrhea, .severity, .symptoms),
        e("dizziness", "Dizziness", .dizziness, .severity, .symptoms),
        e("dry_skin", "Dry Skin", .drySkin, .severity, .symptoms),
        e("fainting", "Fainting", .fainting, .severity, .symptoms),
        e("fatigue", "Fatigue", .fatigue, .severity, .symptoms),
        e("fever", "Fever", .fever, .severity, .symptoms),
        e("body_ache", "Generalized Body Ache", .generalizedBodyAche, .severity, .symptoms),
        e("hair_loss", "Hair Loss", .hairLoss, .severity, .symptoms),
        e("headache", "Headache", .headache, .severity, .symptoms),
        e("heartburn", "Heartburn", .heartburn, .severity, .symptoms),
        e("hot_flashes", "Hot Flashes", .hotFlashes, .severity, .symptoms),
        e("loss_of_smell", "Loss of Smell", .lossOfSmell, .severity, .symptoms),
        e("loss_of_taste", "Loss of Taste", .lossOfTaste, .severity, .symptoms),
        e("lower_back_pain", "Lower Back Pain", .lowerBackPain, .severity, .symptoms),
        e("memory_lapse", "Memory Lapse", .memoryLapse, .severity, .symptoms),
        e("mood_changes", "Mood Changes", .moodChanges, .presence, .symptoms),
        e("nausea", "Nausea", .nausea, .severity, .symptoms),
        e("night_sweats", "Night Sweats", .nightSweats, .severity, .symptoms),
        e("pelvic_pain", "Pelvic Pain", .pelvicPain, .severity, .symptoms),
        e("rapid_heartbeat", "Rapid, Pounding or Fluttering Heartbeat", .rapidPoundingOrFlutteringHeartbeat, .severity, .symptoms),
        e("runny_nose", "Runny Nose", .runnyNose, .severity, .symptoms),
        e("shortness_of_breath", "Shortness of Breath", .shortnessOfBreath, .severity, .symptoms),
        e("sinus_congestion", "Sinus Congestion", .sinusCongestion, .severity, .symptoms),
        e("skipped_heartbeat", "Skipped Heartbeat", .skippedHeartbeat, .severity, .symptoms),
        e("sleep_changes", "Sleep Changes", .sleepChanges, .presence, .symptoms),
        e("sore_throat", "Sore Throat", .soreThroat, .severity, .symptoms),
        e("vaginal_dryness", "Vaginal Dryness", .vaginalDryness, .severity, .symptoms),
        e("vomiting", "Vomiting", .vomiting, .severity, .symptoms),
        e("wheezing", "Wheezing", .wheezing, .severity, .symptoms),
    ]

    private static let other: [HealthMetric] = [
        q("uv_exposure", "UV Index", .uvExposure, "count", .other),
        q("times_fallen", "Number of Times Fallen", .numberOfTimesFallen, "count", .other),
        q("insulin_delivery", "Insulin Delivery", .insulinDelivery, "IU", .other),
        q("underwater_depth", "Underwater Depth", .underwaterDepth, "m", .other),
        q("water_temperature", "Water Temperature", .waterTemperature, "degC", .other),
        e("toothbrushing", "Toothbrushing", .toothbrushingEvent, .event, .other),
        e("handwashing", "Handwashing", .handwashingEvent, .event, .other),
    ]

    private static func q(_ id: String, _ name: String, _ type: HKQuantityTypeIdentifier, _ unit: String,
                          _ category: MetricCategory, on: Bool = false) -> HealthMetric {
        HealthMetric(id: id, displayName: name, kind: .quantity(identifier: type.rawValue, unit: unit), category: category, defaultEnabled: on)
    }

    private static func e(_ id: String, _ name: String, _ type: HKCategoryTypeIdentifier, _ values: CategoryValueSet,
                          _ category: MetricCategory) -> HealthMetric {
        HealthMetric(id: id, displayName: name, kind: .categoryEvent(identifier: type.rawValue, values: values), category: category)
    }
}
