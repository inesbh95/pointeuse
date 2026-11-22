# R8 supprime sinon les classes chargées par réflexion (ML Kit, TensorFlow Lite) :
# la détection de visage plante en release avec « null object reference ».
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_** { *; }
-keep class com.google.android.gms.vision.** { *; }
-keep class com.google.firebase.components.** { *; }
-keep class org.tensorflow.** { *; }
-dontwarn org.tensorflow.**
-dontwarn com.google.mlkit.**

# flutter_local_notifications (rappels de pointage) : sérialisation Gson des notifications programmées
-keep class com.dexterous.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keepattributes Signature
