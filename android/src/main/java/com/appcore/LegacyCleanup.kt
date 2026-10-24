package com.appcore

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import com.appcore.Common.BUNDLE_HISTORY
import com.appcore.Common.LEGACY_CLEANUP_DONE
import com.appcore.Common.PATH
import org.json.JSONArray
import java.io.File
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * One-time removal of what the previous package (react-native-ota-hot-update) left behind:
 * its SharedPreferences file, the bundle folders recorded there, and its git checkout.
 * Those bundles call the old native module name and cannot run on this binary, so nothing
 * is migrated, only deleted.
 *
 * - Runs only while the old preferences exist, and records completion in our own storage, so
 *   it never touches anything again afterwards (e.g. a new git checkout in the same folder).
 * - Only deletes folders the old package created: its unzip folders (see [UNZIP_FOLDER]) and
 *   its git checkouts. A recorded bundle anywhere else is left alone.
 * - Never deletes a folder holding a bundle this package currently uses.
 * - The old preferences are dropped only once every recorded bundle is gone, so an interrupted
 *   or failed run is retried on the next start instead of losing track of the files.
 */
internal object LegacyCleanup {
  private const val LEGACY_PREFS = "HOT-UPDATE-REACT_NATIVE"
  private const val LEGACY_GIT_FOLDER = "git_hot_update"
  private const val TRASH_FOLDER = ".appcore-trash"
  /**
   * The old version renamed each unzipped bundle folder to output_v<version>_<yyyy_MM_dd_HH_mm>
   * (or output_<yyyy_MM_dd_HH_mm>), with the date digits in the device locale.
   */
  private val UNZIP_FOLDER = Regex("""output_(v-?\d+_)?\p{Nd}{4}(_\p{Nd}{2}){4}""")
  private val started = AtomicBoolean(false)

  /** Called on app start, before JS runs. Only cheap checks and renames happen here. */
  fun start(context: Context) {
    if (!started.compareAndSet(false, true)) return
    try {
      val appContext = context.applicationContext ?: context
      val store = SharedPrefs(appContext)
      if (store.getString(LEGACY_CLEANUP_DONE) == "1") return

      val legacyPrefs = appContext.getSharedPreferences(LEGACY_PREFS, Context.MODE_PRIVATE)
      val entries = legacyPrefs.all
      if (entries.isEmpty()) {
        store.putString(LEGACY_CLEANUP_DONE, "1")
        return
      }

      val filesDir = appContext.filesDir
      val trash = File(filesDir, TRASH_FOLDER)
      val inUse = (listOfNotNull(store.getString(PATH)) + historyPaths(store.getString(BUNDLE_HISTORY)))
        .filter { it.isNotEmpty() }
        .map { File(it) }
      val recorded = (listOfNotNull(entries["PATH"] as? String, entries["PREVIOUS_PATH"] as? String) +
        historyPaths(entries["BUNDLE_HISTORY"] as? String))
        .filter { it.isNotEmpty() }
        .map { File(it) }

      // The default checkout folder plus any custom folderName that holds a recorded bundle.
      // Moved aside before JS starts, so a new clone into the same folder can never race with
      // the delete below.
      val checkouts = (listOf(File(filesDir, LEGACY_GIT_FOLDER)) + recorded.mapNotNull { gitCheckoutOf(it, filesDir) })
        .distinctBy { it.canonicalPath }
        .filter { folder -> folder.exists() && inUse.none { isInside(it, folder) } }
      val movedAll = checkouts.all { moveToTrash(it, trash) }
      val unzipFolders = recorded
        .mapNotNull { unzipFolderOf(it) }
        .distinctBy { it.canonicalPath }
        .filter { folder -> inUse.none { isInside(it, folder) } }

      Thread {
        try {
          removeLegacyFiles(appContext, store, legacyPrefs, trash, unzipFolders, movedAll)
        } catch (e: Throwable) {
          // best effort, retried on the next start
        }
      }.start()
    } catch (e: Throwable) {
      // best effort, must never affect app start
    }
  }

  private fun removeLegacyFiles(
    context: Context,
    store: SharedPrefs,
    legacyPrefs: SharedPreferences,
    trash: File,
    unzipFolders: List<File>,
    movedAll: Boolean
  ) {
    var removedAll = movedAll // a checkout that could not be moved aside is retried next start
    if (trash.exists() && !trash.deleteRecursively()) removedAll = false
    unzipFolders.forEach { folder ->
      if (folder.exists() && !folder.deleteRecursively()) removedAll = false
    }

    if (!removedAll) return
    legacyPrefs.edit().clear().commit()
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      context.deleteSharedPreferences(LEGACY_PREFS)
    }
    store.putString(LEGACY_CLEANUP_DONE, "1")
  }

  private fun moveToTrash(folder: File, trash: File): Boolean {
    trash.mkdirs()
    return folder.renameTo(File(trash, UUID.randomUUID().toString()))
  }

  /**
   * The old git mode cloned into filesDir + folderName ("/git_hot_update" unless configured).
   * Returns the folder above [bundle] that holds the .git directory, strictly inside filesDir.
   */
  private fun gitCheckoutOf(bundle: File, filesDir: File): File? {
    var current = bundle.parentFile
    while (current != null && isInside(current, filesDir) && !isSame(current, filesDir)) {
      if (File(current, ".git").exists()) return current
      current = current.parentFile
    }
    return null
  }

  /**
   * The unzip folder [bundle] was extracted into; the bundle file may sit deeper inside
   * (e.g. output_v2_.../dist/index.android.bundle). Null when it is not in one.
   */
  private fun unzipFolderOf(bundle: File): File? {
    var current = bundle.parentFile
    while (current != null) {
      if (UNZIP_FOLDER.matches(current.name)) return current
      current = current.parentFile
    }
    return null
  }

  private fun historyPaths(json: String?): List<String> {
    if (json.isNullOrEmpty()) return emptyList()
    return try {
      val history = JSONArray(json)
      (0 until history.length()).mapNotNull { history.optJSONObject(it)?.optString("path") }
    } catch (e: Exception) {
      emptyList()
    }
  }

  private fun isSame(a: File, b: File) = a.canonicalPath == b.canonicalPath

  private fun isInside(file: File, folder: File): Boolean {
    val child = file.canonicalPath
    val parent = folder.canonicalPath
    return child == parent || child.startsWith(parent + File.separator)
  }
}
