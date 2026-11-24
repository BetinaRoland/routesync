import 'common.dart';
import 'allocation.dart' as a;
import 'comms.dart' as c;
import 'emergency.dart' as e;
import 'insights.dart' as i;
import 'network.dart' as n;
import 'people.dart' as p;
import 'planning.dart' as planning;

/// Every action the screens can ask for. Names match the old server functions so the screens did not need to change.
Future<M> runService(String name, M d) {
  switch (name) {
    case 'previewAcademicRollover':
      return planning.previewAcademicRollover(d);
    case 'applyAcademicRollover':
      return planning.applyAcademicRollover(d);
    case 'saveTransportTemplate':
      return planning.saveTransportTemplate(d);
    case 'duplicateTransportTemplate':
      return planning.duplicateTransportTemplate(d);
    case 'setTransportTemplateActive':
      return planning.setTransportTemplateActive(d);
    case 'saveDailyTransportPlan':
      return planning.saveDailyTransportPlan(d);
    case 'previewInvite':
      return p.previewInvite(d);
    case 'redeemInvite':
      return p.redeemInvite(d);
    case 'importStudents':
      return p.importCollegeData({
        'busRows': const [],
        'studentRows': d['rows'] ?? const [],
        'dryRun': d['dryRun'],
        'duplicatePolicy': d['duplicatePolicy'],
        'confirmedUpdates': d['confirmedUpdates'],
      });
    case 'importTransportData':
      return p.importBusesData(d);
    case 'importCollegeData':
      return p.importCollegeData(d);
    case 'reissueInvite':
      return p.reissueInvite(d);
    case 'updateStudent':
      return p.updateStudent(d);
    case 'assignStudentBoardingPoints':
      return p.assignStudentBoardingPoints(d);
    case 'removeStudent':
      return p.removeStudent(d);
    case 'createDriver':
      return p.createDriver(d);
    case 'createStaff':
      return p.createStaff(d);
    case 'setAccountDisabled':
      return p.setAccountDisabled(d);
    case 'registerDevice':
      return p.registerDevice(d);
    case 'revokeDevice':
      return p.revokeDevice(d);
    case 'saveBus':
      return n.saveBus(d);
    case 'removeBus':
      return n.removeBus(d);
    case 'assignDriver':
      return n.assignDriver(d);
    case 'saveBoardingPoint':
      return n.saveBoardingPoint(d);
    case 'setBoardingPointDuplicateDistance':
      return n.setBoardingPointDuplicateDistance(d);
    case 'searchBoardingPlaces':
      return n.searchBoardingPlaces(d);
    case 'reverseGeocodeBoardingPoint':
      return n.reverseGeocodeBoardingPoint(d);
    case 'saveRoute':
      return n.saveRoute(d);
    case 'deleteBoardingPoint':
      return n.deleteBoardingPoint(d);
    case 'deleteRoute':
      return n.deleteRoute(d);
    case 'setOperationalHours':
      return n.setOperationalHours(d);
    case 'requestBoardingPoint':
      return n.requestBoardingPoint(d);
    case 'selectBoardingPoint':
      return n.selectBoardingPoint(d);
    case 'reviewBoardingRequest':
      return n.reviewBoardingRequest(d);
    case 'proposeAllocation':
      return a.proposeAllocation(d);
    case 'proposeRebalance':
      return a.proposeRebalance(d);
    case 'reviewChangeRequest':
      return a.reviewChangeRequest(d);
    case 'cancelAllocation':
      return a.cancelAllocation(d);
    case 'moveStudent':
      return a.moveStudent(d);
    case 'findAlternatives':
      return a.findAlternatives(d);
    case 'reserveAlternative':
      return a.reserveAlternative(d);
    case 'emergencyReplaceBus':
      return e.emergencyReplaceBus(d);
    case 'emergencyRouteChange':
      return e.emergencyRouteChange(d);
    case 'emergencyReplaceDriver':
      return e.emergencyReplaceDriver(d);
    case 'reviewEmergency':
      return e.reviewEmergency(d);
    case 'driverReport':
      return e.driverReport(d);
    case 'sendAnnouncement':
      return c.sendAnnouncement(d);
    case 'submitFeedback':
      return c.submitFeedback(d);
    case 'replyFeedback':
      return c.replyFeedback(d);
    case 'getMyTransport':
      return c.getMyTransport(d);
    case 'getEta':
      return c.getEta(d);
    case 'insights':
      return i.insights(d);
    case 'replacementSuggestions':
      return i.replacementSuggestions(d);
    default:
      fail('Unknown action: $name');
  }
}
