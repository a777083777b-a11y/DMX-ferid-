set -e
if [ ! -d android ]; then
cp lib/main.dart /tmp/main.dart
cp pubspec.yaml /tmp/pubspec.yaml
flutter create --platforms=android --project-name dmx_rdm_app --org uz.djon .
cp /tmp/main.dart lib/main.dart
cp /tmp/pubspec.yaml pubspec.yaml
rm -rf test
fi
mkdir -p android/app/src/main/res/xml
printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>' '<resources>' '<usb-device vendor-id="1027" product-id="24577" />' '<usb-device vendor-id="1027" product-id="24592" />' '<usb-device vendor-id="1027" product-id="24596" />' '<usb-device vendor-id="1027" product-id="24597" />' '</resources>' > android/app/src/main/res/xml/device_filter.xml
M=android/app/src/main/AndroidManifest.xml
sed -i 's|<application|<uses-feature android:name="android.hardware.usb.host" /><application|' "$M"
sed -i 's|</activity>|<intent-filter><action android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" /></intent-filter><meta-data android:name="android.hardware.usb.action.USB_DEVICE_ATTACHED" android:resource="@xml/device_filter" /></activity>|' "$M"
