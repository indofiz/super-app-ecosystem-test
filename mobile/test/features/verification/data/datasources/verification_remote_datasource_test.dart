import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:smart_app_test/features/auth/data/dto/send_otp_response_dto.dart';
import 'package:smart_app_test/features/auth/data/dto/verify_otp_response_dto.dart';
import 'package:smart_app_test/features/verification/data/bff_verification_api.dart';
import 'package:smart_app_test/features/verification/data/datasources/verification_remote_datasource.dart';

class _MockBffVerificationApi extends Mock implements BffVerificationApi {}

void main() {
  late _MockBffVerificationApi api;
  late VerificationRemoteDataSource remote;

  setUp(() {
    api = _MockBffVerificationApi();
    remote = VerificationRemoteDataSource(api: api);
  });

  test('sendEmailOtp threads bearer through', () async {
    const dto = SendOtpResponseDto(delivery: 'email', expiresIn: 300);
    when(() => api.sendEmailOtp('b')).thenAnswer((_) async => dto);

    final result = await remote.sendEmailOtp(bearer: 'b');
    expect(result, same(dto));
    verify(() => api.sendEmailOtp('b')).called(1);
  });

  test('verifyEmailOtp threads bearer + code through', () async {
    const dto = VerifyOtpResponseDto(
      accessToken: 'tok',
      sessionId: 'sid',
      expiresIn: 3600,
    );
    when(() => api.verifyEmailOtp('b', '123456')).thenAnswer((_) async => dto);

    final result = await remote.verifyEmailOtp(bearer: 'b', code: '123456');
    expect(result, same(dto));
    verify(() => api.verifyEmailOtp('b', '123456')).called(1);
  });

  test('sendPhoneOtp threads bearer + phone through', () async {
    const dto = SendOtpResponseDto(delivery: 'wa', expiresIn: 300);
    when(() => api.sendPhoneOtp('b', '+62...')).thenAnswer((_) async => dto);

    final result = await remote.sendPhoneOtp(bearer: 'b', phone: '+62...');
    expect(result, same(dto));
    verify(() => api.sendPhoneOtp('b', '+62...')).called(1);
  });

  test('verifyPhoneOtp threads bearer + phone + code through', () async {
    const dto = VerifyOtpResponseDto(
      accessToken: 'tok',
      sessionId: 'sid',
      expiresIn: 3600,
    );
    when(() => api.verifyPhoneOtp('b', '+62...', '654321'))
        .thenAnswer((_) async => dto);

    final result = await remote.verifyPhoneOtp(
      bearer: 'b',
      phone: '+62...',
      code: '654321',
    );
    expect(result, same(dto));
    verify(() => api.verifyPhoneOtp('b', '+62...', '654321')).called(1);
  });

  test('dispose disposes the underlying API', () async {
    when(api.dispose).thenAnswer((_) async {});

    await remote.dispose();
    verify(api.dispose).called(1);
  });
}
