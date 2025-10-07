# Android 16KB Page Size Compatibility Checker

A comprehensive PowerShell script to verify that your Android APK, AAB, AAR, or native libraries (.so files) are compatible with Android's 16KB page size requirement.

## 🔍 What Does This Check?

Starting with Android 15, devices may use 16KB memory page sizes instead of the traditional 4KB. Apps with improperly aligned native libraries will fail to load on these devices.

This script performs **comprehensive validation** that goes beyond simple alignment checks:

- ✅ **PT_LOAD segment alignment** (`p_align >= 16384`)
- ✅ **Virtual address alignment** (`p_vaddr % p_align == 0`)
- ✅ **File offset alignment** (`p_offset % p_align == 0`)
- ✅ **Congruence requirement** (`p_vaddr % p_align == p_offset % p_align`)
- ✅ **Android property note detection** (`.note.gnu.property`)

### Why This Matters

Many basic checkers only verify the `p_align` field, but the Android dynamic linker validates all address and offset alignments at runtime. This script catches the issues that will actually cause your app to fail on 16KB devices.

## 📋 Requirements

- **Windows PowerShell 5.1+** (or PowerShell Core 7+)
- **Android NDK** (version 27 or later recommended)

## 🚀 Quick Start

### Step 1: Download the Script

Save the script as `check-16kb-alignment.ps1`

### Step 2: Install Android NDK

Choose **ONE** of the following methods:

#### Option A: Using Android Studio (Easiest)

1. Open **Android Studio**
2. Go to **File** → **Settings** (or **Android Studio** → **Preferences** on Mac)
3. Navigate to **Appearance & Behavior** → **System Settings** → **Android SDK**
4. Click the **SDK Tools** tab
5. Check **NDK (Side by side)**
6. Click **OK** to download and install

The NDK will be installed at:
```
Windows: C:\Users\<username>\AppData\Local\Android\Sdk\ndk\<version>
macOS: ~/Library/Android/sdk/ndk/<version>
Linux: ~/Android/Sdk/ndk/<version>
```

#### Option B: Manual Download

1. Visit the [Android NDK Downloads](https://developer.android.com/ndk/downloads) page
2. Download the appropriate version for your OS:
   - **Windows**: `android-ndk-r27-windows.zip` (or later)
   - **macOS**: `android-ndk-r27-darwin.dmg`
   - **Linux**: `android-ndk-r27-linux.zip`
3. Extract to a location of your choice (e.g., `C:\Android\ndk\27.0.0`)

#### Option C: Using SDK Manager Command Line

```bash
# Windows
sdkmanager "ndk;27.0.12077973"

# macOS/Linux
./sdkmanager "ndk;27.0.12077973"
```

### Step 3: Run the Script

**Interactive Mode** (Easiest - script will prompt you):
```powershell
.\check-16kb-alignment.ps1
```

**Command Line Mode**:
```powershell
.\check-16kb-alignment.ps1 -Path "C:\path\to\your\app.apk" -NdkPath "C:\Android\Sdk\ndk\27.0.0"
```

**With Report Output**:
```powershell
.\check-16kb-alignment.ps1 -Path ".\app.apk" -NdkPath ".\ndk\27.0.0" -ReportPath ".\report.txt"
```

## 📝 Usage Examples

### Check an APK
```powershell
.\check-16kb-alignment.ps1 -Path "C:\MyApp\app-release.apk"
```

### Check an AAB (Android App Bundle)
```powershell
.\check-16kb-alignment.ps1 -Path "C:\MyApp\app-release.aab"
```

### Check an AAR Library
```powershell
.\check-16kb-alignment.ps1 -Path "C:\Libraries\mylibrary.aar"
```

### Check a Directory of .so Files
```powershell
.\check-16kb-alignment.ps1 -Path "C:\MyProject\jniLibs"
```

### Check a Single .so File
```powershell
.\check-16kb-alignment.ps1 -Path "C:\MyProject\arm64-v8a\libmyapp.so"
```

## 📊 Understanding the Output

### ✅ Success Output
```
Checking: libexample.so
  PASS - All segments properly aligned

===FINAL RESULT===
SUCCESS: All .so files pass 16KB alignment checks
```

### ❌ Failure Output
```
Checking: libproblem.so
  FAIL - See details below:
    - p_vaddr (0x4F4BC0) not aligned to p_align (16384)
    - p_offset (0x4ECBC0) not aligned to p_align (16384)

===FINAL RESULT===
FAILED: 1 non-compliant file(s):
  - libproblem.so
```

### ⚠️ Warning Output
```
  WARNING: No .note.gnu.property section found (may indicate old NDK)
```
This means the library was built with an older NDK version. It may still work but should be recompiled.

## 🔧 Fixing Alignment Issues

If the script reports failures, here's how to fix them:

### 1. Update Your NDK
Ensure you're using **NDK 27 or later**:
```gradle
// In your gradle.properties or build.gradle
android.ndkVersion = "27.0.12077973"
```

### 2. Enable 16KB Page Support
Add to your app's `build.gradle`:
```gradle
android {
    defaultConfig {
        ndk {
            abiFilters 'arm64-v8a'
        }
    }
    
    // For CMake projects
    externalNativeBuild {
        cmake {
            arguments '-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON'
        }
    }
}
```

### 3. Add Linker Flags (For Native Builds)
If building with CMake or ndk-build:

**CMakeLists.txt**:
```cmake
target_link_options(your_library PRIVATE
    -Wl,-z,max-page-size=16384
)
```

**Android.mk**:
```makefile
LOCAL_LDFLAGS += -Wl,-z,max-page-size=16384
```

### 4. Third-Party Libraries
If the failing library is from a third party:
- Check for updated versions that support 16KB pages
- Contact the library maintainer
- Consider alternative libraries
- As a last resort, use compatibility mode (not recommended for production)

## 🐛 Troubleshooting

### "llvm-readobj not found"
- Verify your NDK path is correct
- Ensure you downloaded the complete NDK package
- Check that the NDK version is 23 or later

### "Execution Policy" Error
Run PowerShell as Administrator and execute:
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
```

### Script Won't Run
Ensure you're in the correct directory:
```powershell
cd C:\path\to\script
.\check-16kb-alignment.ps1
```

### No .so Files Found
- Verify you're checking arm64-v8a architecture (the script only checks arm64-v8a)
- Ensure the APK/AAB actually contains native libraries
- Check if the archive is corrupted

## 📱 Testing on Emulator

To test your app on a 16KB page size emulator:

1. Open **Android Studio** → **Device Manager**
2. Create a new **Virtual Device**
3. Select a system image with **16KB page size support**:
   - Look for "16 KB" in the release name
   - API 35+ recommended
4. Run your app and watch for the compatibility warning

## 🔗 Related Resources

- [Android 16KB Page Size Documentation](https://developer.android.com/guide/practices/page-sizes)
- [NDK Downloads](https://developer.android.com/ndk/downloads)
- [Google's 16KB Support Guide](https://developer.android.com/guide/practices/page-sizes)

## 📄 Script Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|---------|
| `-Path` | Path to APK/AAB/AAR/ZIP/.so file or directory | No* | Interactive prompt |
| `-NdkPath` | Path to Android NDK root directory | No* | Saved from previous run |
| `-ReportPath` | Path to save detailed text report | No | None |
| `-MinAlign` | Minimum alignment requirement (bytes) | No | 16384 |

*Required if not running in interactive mode

## 💾 Persistent Configuration

The script saves your NDK path to `ndkpath.dat` in the script directory. On subsequent runs, you can press Enter to use the saved path.

To reset, simply delete `ndkpath.dat`.

## 🤝 Contributing

Issues and pull requests are welcome! Please ensure any changes maintain compatibility with PowerShell 5.1+.

## 📜 License

This script is provided as-is for use in Android app development and testing.

## ⚠️ Important Notes

- The script only checks **arm64-v8a** architecture (64-bit ARM), as this is the primary architecture affected by 16KB page requirements
- Always test on actual 16KB emulators or devices after validation
- This script checks ELF alignment at the binary level, not runtime behavior
- Passing this check is necessary but may not be sufficient for all edge cases

## 📞 Support

If you encounter issues:
1. Check the [Troubleshooting](#-troubleshooting) section
2. Verify your NDK installation
3. Open an issue with:
   - PowerShell version (`$PSVersionTable.PSVersion`)
   - NDK version
   - Error message output
   - Type of file being checked (APK/AAB/AAR/etc.)

---

**Made with ❤️ for the Android developer community**