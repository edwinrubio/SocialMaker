# LiteRT binds its Java classes from JNI by name.
-keep class org.tensorflow.lite.** { *; }
-dontwarn org.tensorflow.lite.**
