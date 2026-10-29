import UIKit
import Flutter
import GoogleMaps

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var healthKitWorkoutChannel: HealthKitWorkoutChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
      GMSServices.provideAPIKey(Env.googleMapApiKey);
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "HealthKitWorkoutChannel") {
      healthKitWorkoutChannel = HealthKitWorkoutChannel(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
