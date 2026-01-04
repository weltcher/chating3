allprojects {
    repositories {
        // 使用国内镜像源加速下载
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        maven { url = uri("https://maven.aliyun.com/repository/jcenter") }
        // 🔴 腾讯云 TRTC/IM SDK Maven 仓库
        maven { url = uri("https://mirrors.tencent.com/nexus/repository/maven-public/") }
        // 🔴 华为 HMS 推送 Maven 仓库
        maven { url = uri("https://developer.huawei.com/repo/") }
        // 备用原始源
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
