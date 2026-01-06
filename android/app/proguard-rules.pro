# Flutter 相关
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Google Play Core (for deferred components)
-keep class com.google.android.play.core.** { *; }
-dontwarn com.google.android.play.core.**

# Agora SDK
-keep class io.agora.** { *; }
-dontwarn io.agora.**

# ========== 腾讯云 TRTC/TUICallKit SDK ==========
# 保留所有腾讯云相关类
-keep class com.tencent.** { *; }
-dontwarn com.tencent.**

# TRTC SDK 核心
-keep class com.tencent.liteav.** { *; }
-keep class com.tencent.trtc.** { *; }

# IM SDK
-keep class com.tencent.imsdk.** { *; }

# TUICore
-keep class com.tencent.qcloud.** { *; }
-keep class com.tencent.tuicore.** { *; }
-keep class com.tencent.cloud.** { *; }

# TUICallKit
-keep class com.tencent.qcloud.tuikit.** { *; }
-dontwarn com.tencent.qcloud.tuikit.**

# 腾讯云 SDK 内部使用的混淆类名（关键！）
-keep class L5.** { *; }
-keep class M5.** { *; }
-keep class C5.** { *; }
-keep class N5.** { *; }
-keep class O5.** { *; }
-keep class P5.** { *; }
-keep class Q5.** { *; }
-keep class R5.** { *; }
-keep class S5.** { *; }
-keep class T5.** { *; }

# 保留所有 JNI 相关类和方法
-keepclasseswithmembers class * {
    native <methods>;
}
-keepclasseswithmembernames class * {
    native <methods>;
}

# 保留所有包含 JNI_OnLoad 的类
-keep class * {
    *** JNI_OnLoad(...);
}

# ========== SQLCipher ==========
-keep class net.sqlcipher.** { *; }
-keep class net.sqlcipher.database.** { *; }
-dontwarn net.sqlcipher.**

# ========== Gson ==========
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }

# ========== 通用规则 ==========
# 保留枚举
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# 保留 Parcelable
-keepclassmembers class * implements android.os.Parcelable {
    public static final android.os.Parcelable$Creator CREATOR;
}

# 保留 Serializable
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# WebView
-keepclassmembers class * extends android.webkit.WebViewClient {
    public void *(android.webkit.WebView, java.lang.String, android.graphics.Bitmap);
    public boolean *(android.webkit.WebView, java.lang.String);
}
-keepclassmembers class * extends android.webkit.WebViewClient {
    public void *(android.webkit.WebView, java.lang.String);
}

# 移除日志（release 模式）
-assumenosideeffects class android.util.Log {
    public static *** d(...);
    public static *** v(...);
    public static *** i(...);
}
