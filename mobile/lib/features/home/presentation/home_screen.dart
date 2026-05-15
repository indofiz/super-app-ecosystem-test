import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../_dev/dev_dashboard.dart';
import '../../auth/presentation/bloc/auth_bloc.dart';
import 'widgets/verification_banner.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: [
          if (kDebugMode) const DevRefreshAction(),
          IconButton(
            tooltip: 'Logout',
            icon: const Icon(Icons.logout),
            onPressed: () =>
                context.read<AuthBloc>().add(const AuthLogoutRequested()),
          ),
        ],
      ),
      body: BlocBuilder<AuthBloc, AuthState>(
        builder: (context, state) {
          final session = state.session;
          if (session == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              const VerificationBanner(),
              Expanded(
                child: kDebugMode
                    ? DevDashboard(session: session)
                    : const _CitizenHomePlaceholder(),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _CitizenHomePlaceholder extends StatelessWidget {
  const _CitizenHomePlaceholder();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Selamat datang.',
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
