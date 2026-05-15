import 'package:equatable/equatable.dart';

/// Wire-shape DTO for `GET /api/profile` (Kong-side).
///
/// Today the only consumer is the dev dashboard, which renders the raw
/// JSON for hand-inspection of the upstream service's response shape.
/// [raw] is preserved so that preview keeps working while real
/// `/api/*` features pull their own typed fields off the DTO as they
/// ship (audit-002 H-03).
///
/// Once a real citizen-facing consumer lands, add the typed fields it
/// needs and let it consume those instead of `raw`. The dev dashboard
/// stays on `raw` indefinitely — that's the point of the dashboard.
class ProfileResponseDto extends Equatable {
  const ProfileResponseDto({required this.raw});

  factory ProfileResponseDto.fromJson(Map<String, dynamic> body) {
    return ProfileResponseDto(raw: Map<String, dynamic>.unmodifiable(body));
  }

  /// The full response body as the upstream sent it. Unmodifiable so
  /// callers can't accidentally mutate shared state across requests.
  final Map<String, dynamic> raw;

  @override
  List<Object?> get props => [raw];
}
