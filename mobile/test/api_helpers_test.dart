import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'package:mobile/models/report.dart';
import 'package:mobile/services/safety_api_service.dart';
import 'package:mobile/theme.dart';
import 'package:mobile/widgets/map_widgets.dart';
import 'package:mobile/services/sos_service.dart';
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

  group('nearestDistrict', () {
    DistrictCrime d(String name, double lat, double lng, {double intensity = 0.1}) => DistrictCrime(
          district: name, state: 'TN', year: 2015, totalCrimes: 10, intensity: intensity, point: LatLng(lat, lng));

    test('picks the closest district and reports its distance in km', () {
      final r = nearestDistrict(
        [d('Far', 28.6, 77.2), d('Vellore', 12.9165, 79.1325), d('Chittoor', 13.2, 79.1)],
        const LatLng(12.9692, 79.1559),
      );
      expect(r, isNotNull);
      expect(r!.$1.district, 'Vellore');
      expect(r.$2, inInclusiveRange(5, 8));
    });

    test('returns null when nothing is within the limit, or there is no data', () {
      expect(nearestDistrict([d('Delhi', 28.6, 77.2)], const LatLng(12.97, 79.16)), isNull);
      expect(nearestDistrict([], const LatLng(12.97, 79.16)), isNull);
    });
  });

  group('districtColor', () {
    test('runs green (low) to red (high)', () {
      expect(districtColor(0), AppColors.success);
      expect(districtColor(1), AppColors.destructive);
      expect(districtColor(0.5), AppColors.warning);
    });
  });

  group('route check timeout', () {
    test('outlasts the server fallback (about 8 s road data + about 17 s scoring)', () {
      expect(SafetyApiService.routeCheckTimeout, greaterThanOrEqualTo(const Duration(seconds: 28)));
    });
  });

  group('sosServerSuccessMessage', () {
    test('a normal send says the circle was alerted with the location', () {
      expect(sosServerSuccessMessage({'template_mode': false}),
          'Your trusted circle was alerted with your location.');
      expect(sosServerSuccessMessage({'results': []}),
          'Your trusted circle was alerted with your location.');
      expect(sosServerSuccessMessage(null),
          'Your trusted circle was alerted with your location.');
    });

    test('template mode says the location was NOT sent', () {
      final text = sosServerSuccessMessage({'template_mode': true});
      expect(text, contains('without your location'));
      expect(text, isNot(contains('alerted with your location')));
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
