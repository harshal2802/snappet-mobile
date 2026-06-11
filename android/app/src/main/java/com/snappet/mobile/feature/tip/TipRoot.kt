// Import necessary libraries
import com.google.android.material.snackbar.Snackbar

// ...

// Add a snackbar to confirm the commit
fun commit() {
    val snackbar = Snackbar.make(binding.root, "Commit successful", Snackbar.LENGTH_SHORT)
    snackbar.show()
    // Add debounce to prevent double-tap
    binding.commitButton.isEnabled = false
    Handler(Looper.getMainLooper()).postDelayed({ binding.commitButton.isEnabled = true }, 500)
}