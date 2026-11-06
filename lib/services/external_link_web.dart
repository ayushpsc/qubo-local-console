import 'package:web/web.dart' as web;

bool openExternalLink(Uri uri) {
  web.window.open(uri.toString(), '_blank');
  return true;
}

bool canEmbedLocalStream(Uri uri) =>
    web.window.location.protocol != 'https:' || uri.scheme == 'https';
