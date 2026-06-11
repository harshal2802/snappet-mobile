// Import necessary libraries
import com.google.android.material.snackbar.Snackbar

// ...

// Auto-dismiss the log confirmation pill after 3 seconds
fun logConfirmation() {
    val snackbar = Snackbar.make(binding.root, "Log confirmation", Snackbar.LENGTH_SHORT)
    snackbar.show()
    Handler(Looper.getMainLooper()).postDelayed({ snackbar.dismiss() }, 3000)
    // Add an inline undo
    snackbar.setAction("Undo") {
        // Undo the log confirmation
    }
}

// Handle BLE permission denial
fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
    if (requestCode == REQUEST_BLE_PERMISSION) {
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_DENIED) {
            val snackbar = Snackbar.make(binding.root, "Snappet needs Nearby devices permission to find your board", Snackbar.LENGTH_INDEFINITE)
            snackbar.setAction("Settings") {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                intent.data = Uri.parse("package:com.snappet.mobile")
                startActivity(intent)
            }
            snackbar.show()
        }
    }
}