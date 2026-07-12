// Platform-conditional export of the direct FCM sender:
//  * native (Android/iOS/Windows/macOS/Linux): real HTTP v1 sender
//    authenticated with a service-account key from secure storage;
//  * web: stub — the Cloud Function covers the wake push there.
export 'fcm_direct_sender_io.dart'
    if (dart.library.html) 'fcm_direct_sender_stub.dart';
