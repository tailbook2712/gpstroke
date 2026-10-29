import Flutter
import CoreLocation
import HealthKit

/// HealthKit のワークアウトとルート（座標列）を Flutter に渡すチャネル
/// Apple Watch や Garmin Connect などがヘルスケアに書き込んだアクティビティを取得する
class HealthKitWorkoutChannel {
  static let channelName = "gpstroke/healthkit"

  private let healthStore = HKHealthStore()
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: HealthKitWorkoutChannel.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private var readTypes: Set<HKObjectType> {
    var types: Set<HKObjectType> = [
      HKObjectType.workoutType(),
      HKSeriesType.workoutRoute(),
    ]
    if let steps = HKObjectType.quantityType(forIdentifier: .stepCount) {
      types.insert(steps)
    }
    return types
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(HKHealthStore.isHealthDataAvailable())
    case "requestAuthorization":
      requestAuthorization(result: result)
    case "fetchRecentWorkouts":
      let args = call.arguments as? [String: Any]
      let days = args?["days"] as? Int ?? 30
      let limit = args?["limit"] as? Int ?? 20
      fetchRecentWorkouts(days: days, limit: limit, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func requestAuthorization(result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      result(false)
      return
    }
    // 読み取り権限の許可状況はプライバシー保護のため取得できないので，
    // ダイアログが正常に完了したかどうかだけを返す
    healthStore.requestAuthorization(toShare: nil, read: readTypes) { success, error in
      DispatchQueue.main.async {
        if let error = error {
          result(FlutterError(code: "AUTH_ERROR", message: error.localizedDescription, details: nil))
        } else {
          result(success)
        }
      }
    }
  }

  /// 直近のワークアウトを取得し，ルートを持つものだけを返す
  private func fetchRecentWorkouts(days: Int, limit: Int, result: @escaping FlutterResult) {
    let startDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())
    let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: [])
    let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

    let query = HKSampleQuery(
      sampleType: HKObjectType.workoutType(),
      predicate: predicate,
      limit: limit,
      sortDescriptors: [sort]
    ) { [weak self] _, samples, error in
      guard let self = self else { return }
      if let error = error {
        DispatchQueue.main.async {
          result(FlutterError(code: "QUERY_ERROR", message: error.localizedDescription, details: nil))
        }
        return
      }

      let workouts = (samples as? [HKWorkout]) ?? []
      var items = [[String: Any]?](repeating: nil, count: workouts.count)
      let group = DispatchGroup()

      for (index, workout) in workouts.enumerated() {
        group.enter()
        self.fetchRouteLocations(for: workout) { locations in
          guard !locations.isEmpty else {
            group.leave()
            return
          }
          self.fetchSteps(for: workout) { steps in
            items[index] = self.serialize(workout: workout, locations: locations, steps: steps)
            group.leave()
          }
        }
      }

      group.notify(queue: .main) {
        result(items.compactMap { $0 })
      }
    }
    healthStore.execute(query)
  }

  /// ワークアウトに紐づく全ルートの座標を取得
  private func fetchRouteLocations(for workout: HKWorkout, completion: @escaping ([CLLocation]) -> Void) {
    let predicate = HKQuery.predicateForObjects(from: workout)
    let routeQuery = HKSampleQuery(
      sampleType: HKSeriesType.workoutRoute(),
      predicate: predicate,
      limit: HKObjectQueryNoLimit,
      sortDescriptors: nil
    ) { [weak self] _, samples, _ in
      guard let self = self, let routes = samples as? [HKWorkoutRoute], !routes.isEmpty else {
        completion([])
        return
      }

      let lock = NSLock()
      var allLocations: [CLLocation] = []
      let group = DispatchGroup()

      for route in routes {
        group.enter()
        var finished = false
        let locationQuery = HKWorkoutRouteQuery(route: route) { _, locations, done, _ in
          if let locations = locations {
            lock.lock()
            allLocations.append(contentsOf: locations)
            lock.unlock()
          }
          // エラー時は done が false のまま呼ばれなくなることがないよう，locations が nil でも終了扱いにする
          if (done || locations == nil) && !finished {
            finished = true
            group.leave()
          }
        }
        self.healthStore.execute(locationQuery)
      }

      group.notify(queue: .global()) {
        completion(allLocations.sorted { $0.timestamp < $1.timestamp })
      }
    }
    healthStore.execute(routeQuery)
  }

  /// ワークアウト期間中の歩数合計を取得（取得できない場合は nil）
  private func fetchSteps(for workout: HKWorkout, completion: @escaping (Int?) -> Void) {
    guard let stepType = HKObjectType.quantityType(forIdentifier: .stepCount) else {
      completion(nil)
      return
    }
    let predicate = HKQuery.predicateForSamples(
      withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)
    let query = HKStatisticsQuery(
      quantityType: stepType,
      quantitySamplePredicate: predicate,
      options: .cumulativeSum
    ) { _, statistics, _ in
      let steps = statistics?.sumQuantity()?.doubleValue(for: .count())
      completion(steps.map { Int($0) })
    }
    healthStore.execute(query)
  }

  private func serialize(workout: HKWorkout, locations: [CLLocation], steps: Int?) -> [String: Any] {
    var item: [String: Any] = [
      "uuid": workout.uuid.uuidString,
      "activityType": workout.workoutActivityType.rawValue,
      "activityName": activityName(for: workout.workoutActivityType),
      "sourceName": workout.sourceRevision.source.name,
      "startDate": workout.startDate.timeIntervalSince1970 * 1000,
      "endDate": workout.endDate.timeIntervalSince1970 * 1000,
      "positions": locations.map { location in
        [
          "latitude": location.coordinate.latitude,
          "longitude": location.coordinate.longitude,
          "altitude": location.altitude,
          "timestamp": location.timestamp.timeIntervalSince1970 * 1000,
        ]
      },
    ]
    if let meters = workout.totalDistance?.doubleValue(for: .meter()) {
      item["distanceMeters"] = meters
    }
    if let steps = steps {
      item["steps"] = steps
    }
    return item
  }

  private func activityName(for type: HKWorkoutActivityType) -> String {
    switch type {
    case .walking: return "ウォーキング"
    case .running: return "ランニング"
    case .hiking: return "ハイキング"
    case .cycling: return "サイクリング"
    default: return "ワークアウト"
    }
  }
}
