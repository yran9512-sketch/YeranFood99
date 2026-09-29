self.addEventListener('push', function (event) {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = { title: 'YeranFood', body: 'Ordering is open!' };
  }

  const title = data.title || 'YeranFood';
  const options = {
    body: data.body || '',
    tag: data.tag || 'ordering-open',
    data: { url: data.url || '/' },
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', function (event) {
  event.notification.close();

  const target = new URL(
    event.notification.data && event.notification.data.url
      ? event.notification.data.url
      : '/',
    self.location.origin
  ).href;

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (clients) {
      const existing = clients.find(function (client) {
        return client.url === target;
      });

      if (existing) return existing.focus();
      return self.clients.openWindow(target);
    })
  );
});