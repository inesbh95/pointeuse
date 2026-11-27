import 'package:flutter_test/flutter_test.dart';
import 'package:pointeuse_admin/tickets/tickets.dart';

void main() {
  // Doit rester identique à ticket_transition_allowed() (migration 20261127130000_tickets.sql).
  test('transitions de l\'employé assigné', () {
    final allowed = <(TicketStatus, TicketStatus)>{
      for (final a in TicketStatus.values)
        for (final b in TicketStatus.values)
          if (canMoveTicket(a, b, admin: false)) (a, b),
    };
    expect(allowed, {
      (TicketStatus.todo, TicketStatus.inProgress),
      (TicketStatus.inProgress, TicketStatus.blocked),
      (TicketStatus.inProgress, TicketStatus.review),
      (TicketStatus.blocked, TicketStatus.inProgress),
      (TicketStatus.review, TicketStatus.inProgress),
    });
  });

  test("l'admin peut tout changer, sauf vers le même statut", () {
    for (final a in TicketStatus.values) {
      for (final b in TicketStatus.values) {
        expect(canMoveTicket(a, b, admin: true), a != b);
      }
    }
  });

  test('statuts lus depuis la base', () {
    expect(TicketStatus.of('in_progress'), TicketStatus.inProgress);
    expect(TicketStatus.of('inconnu'), TicketStatus.todo);
    expect(TicketStatus.done.closed && TicketStatus.cancelled.closed && !TicketStatus.review.closed, isTrue);
  });
}
