import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:mobile/models/report.dart';
import 'package:mobile/utils/json_utils.dart';

http.Response res(int code, String body) => http.Response(body, code);

void main() {
  group('tryDecodeMap / tryDecodeList', () {
    test('decodes an object', () {
      expect(tryDecodeMap('{"a": 1}'), {'a': 1});
    });

    test('never throws on an HTML error page, empty body, or a list', () {
      expect(tryDecodeMap('<html><body>500</body></html>'), isNull);
      expect(tryDecodeMap(''), isNull);
      expect(tryDecodeMap('[1,2]'), isNull);
      expect(tryDecodeList('<html></html>'), isNull);
      expect(tryDecodeList('[1,2]'), [1, 2]);
    });
  });

  group('isSessionExpiredResponse', () {
    test('a Flask-JWT 401 ({"msg": ...}) means the session ended', () {
      expect(isSessionExpiredResponse(res(401, '{"msg":"Token has expired"}')), isTrue);
      expect(isSessionExpiredResponse(res(401, '{"msg":"Missing Authorization Header"}')), isTrue);
    });

    test('our own wrong-password 401s must NOT sign the user out', () {
      expect(isSessionExpiredResponse(res(401, '{"error":"Current password is incorrect"}')), isFalse);
      expect(isSessionExpiredResponse(res(401, '{"verified": false}')), isFalse);
    });

    test('a malformed or re-signed token (422 {"msg": ...}) is also a dead session', () {
      expect(isSessionExpiredResponse(res(422, '{"msg":"Signature verification failed"}')), isTrue);
    });

    test('other statuses and non-JSON bodies are not session expiry', () {
      expect(isSessionExpiredResponse(res(403, '{"msg":"x"}')), isFalse);
      expect(isSessionExpiredResponse(res(401, '<html>nope</html>')), isFalse);
    });
  });

  group('errorMessage', () {
    test('uses the server error when there is one', () {
      expect(errorMessage(res(400, '{"error":"Unknown category"}')), 'Unknown category');
    });

    test('an HTML 500 reads as a server error, not "cannot reach the server"', () {
      expect(errorMessage(res(500, '<html>Internal Server Error</html>')), 'Server error, try again.');
    });

    test('a JWT 401 asks the user to sign in again', () {
      expect(errorMessage(res(401, '{"msg":"Token has expired"}')),
          'Your session expired. Please sign in again.');
    });

    test('falls back for other failures', () {
      expect(errorMessage(res(404, 'nope'), fallback: 'Could not load.'), 'Could not load.');
    });
  });

  group('Report.fromJson', () {
    final base = {'complaint_id': 'AB12CD34', 'status': 'UNDER_REVIEW'};

    test('takes the timeline from the server status_flow', () {
      final r = Report.fromJson({
        ...base,
        'status_flow': ['SUBMITTED', 'UNDER_REVIEW', 'RESOLVED'],
      });
      expect(r.statusFlow, ['SUBMITTED', 'UNDER_REVIEW', 'RESOLVED']);
      expect(r.statusIndex, 1);
    });

    test('falls back to the default flow for an older server', () {
      final r = Report.fromJson(base);
      expect(r.statusFlow, Report.defaultStatusFlow);
      expect(r.statusIndex, 1);
    });

    test('reads chain state, retry flag, and location text', () {
      final r = Report.fromJson({
        ...base,
        'chain_status': 'failed',
        'chain_can_retry': true,
        'status_on_chain': 'SUBMITTED',
        'location_text': 'VIT Gate',
      });
      expect(r.chainFailed, isTrue);
      expect(r.chainCanRetry, isTrue);
      expect(r.statusOnChain, 'SUBMITTED');
      expect(r.locationText, 'VIT Gate');
    });

    test('a report is "pending" until the server says otherwise', () {
      expect(Report.fromJson(base).chainStatus, 'pending');
      expect(Report.fromJson({...base, 'chain_status': 'confirmed'}).chainConfirmed, isTrue);
    });

    test('an unknown status code does not break the labels', () {
      final r = Report.fromJson({...base, 'status': 'ON_HOLD', 'status_flow': ['SUBMITTED', 'ON_HOLD']});
      expect(r.statusLabel, 'On Hold');
      expect(Report.stepTitle('ON_HOLD'), 'On Hold');
    });
  });
}
