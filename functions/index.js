// Watches `public_timetable/current` (the doc the admin app publishes to via
// DataEntryViewModel.publishForStudents / pickAndUploadTimetableDocument)
// and pushes a real phone notification to every viewer-app install whenever
// the admin actually publishes a new schedule or uploads a new document.
//
// Deliberately does NOT fire on every write to that doc — e.g. toggling
// serverEnabled (maintenance mode) or editing documentTitle alone must not
// spam a "new timetable" notification. Only publishedAt / documentUploadedAt
// actually changing counts as "there's something new".
const { onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { initializeApp } = require('firebase-admin/app');
const { getMessaging } = require('firebase-admin/messaging');

initializeApp();

const TOPIC = 'timetable_updates';

function tsEquals(a, b) {
  if (!a && !b) return true;
  if (!a || !b) return false;
  const am = typeof a.toMillis === 'function' ? a.toMillis() : a;
  const bm = typeof b.toMillis === 'function' ? b.toMillis() : b;
  return am === bm;
}

exports.notifyOnPublish = onDocumentUpdated('public_timetable/current', async (event) => {
  const before = event.data.before.data() || {};
  const after = event.data.after.data() || {};

  const schedulePublished = !tsEquals(before.publishedAt, after.publishedAt);
  const documentUploaded = after.documentUploadedAt != null &&
      !tsEquals(before.documentUploadedAt, after.documentUploadedAt);

  if (!schedulePublished && !documentUploaded) return;

  const docTitle = after.documentTitle || 'Timetable Document';
  const title = documentUploaded ? `New ${docTitle} Available` : 'Timetable Updated';
  const body = documentUploaded
      ? `A new ${docTitle.toLowerCase()} has been uploaded. Tap to view.`
      : 'The schedule has been updated. Open the app to see what changed.';

  await getMessaging().send({
    topic: TOPIC,
    notification: { title, body },
    android: {
      priority: 'high',
      notification: { channelId: 'timetable_updates' },
    },
  });
});
