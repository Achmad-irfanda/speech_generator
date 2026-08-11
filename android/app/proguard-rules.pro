# ONNX Runtime dipanggil dari kode native lewat JNI berdasarkan nama kelas.
# R8 tidak bisa melihat pemanggilan itu dan akan membuang kelasnya.
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**