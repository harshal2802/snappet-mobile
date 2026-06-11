// Import necessary libraries
import com.google.android.material.snackbar.Snackbar

// ...

// Replace the delete function with a snackbar that allows undo
fun deleteEntry(entry: Entry) {
    val snackbar = Snackbar.make(binding.root, "Deleted — Undo", Snackbar.LENGTH_LONG)
    snackbar.setAction("Undo") {
        // Undo the deletion
        dao.insert(entry)
    }
    snackbar.show()
    dao.delete(entry)
}