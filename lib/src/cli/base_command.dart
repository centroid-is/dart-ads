/// The shared base for every `ads` verb: [BaseAdsCommand], which owns the
/// error→exit-code contract (CLI-08) so each verb body stays about its own work.
///
/// [BaseAdsCommand.guarded] runs a verb body and maps a thrown error to one of
/// the four stable exit codes, rendering it to stderr, IN THIS PRECEDENCE:
///   1. transport family (`AdsTimeoutException`, `AdsConnectionException`,
///      `SocketException`) → exit `3`;
///   2. ADS family (`AdsException`, incl. `AdsRoutingException`) → exit `1`,
///      printed as `ads error 0x<hex> <NAME>: <text>` — the human-readable name
///      is ALWAYS present, never bare hex alone;
///   3. usage family (`UsageException`, `FormatException`, `ArgumentError`) →
///      exit `2`.
/// Anything else is an unexpected fault: printed and mapped to exit `1`.
///
/// `dart:io` is imported for stderr and `SocketException`; verb commands live
/// in `commands/` and subclass this.
library;

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dart_ads/dart_ads.dart';

import 'exit_codes.dart';

/// A `Command<int>` whose subclasses run their work inside [guarded] so every
/// verb shares the exit-code + error-rendering contract.
abstract class BaseAdsCommand extends Command<int> {
  /// Runs [body], returning its exit code, and maps any thrown error to a
  /// stable exit code (rendering it to stderr) per the class precedence.
  Future<int> guarded(Future<int> Function() body) async {
    try {
      return await body();
    } on AdsTimeoutException catch (error) {
      // Transport family (1/3): a request outlived its timeout.
      stderr.writeln('transport error: $error');
      return exitTransport;
    } on AdsConnectionException catch (error) {
      // Transport family (2/3): the connection dropped / was never established.
      stderr.writeln('transport error: $error');
      return exitTransport;
    } on SocketException catch (error) {
      // Transport family (3/3): the dial itself was refused/unreachable.
      stderr.writeln('transport error: ${error.message}');
      return exitTransport;
    } on AdsException catch (error) {
      // ADS family (incl. AdsRoutingException): always render the human name
      // alongside the code — never bare hex alone.
      stderr.writeln(
        'ads error 0x${error.code.toRadixString(16)} '
        '${adsErrorName(error.code)}: ${adsErrorText(error.code)}',
      );
      return exitAdsError;
    } on UsageException catch (error) {
      // Usage family: bad flags/values. Print just the message (an empty
      // usage string from connectFromGlobals must not print a blank block).
      stderr.writeln(error.message);
      return exitUsage;
    } on FormatException catch (error) {
      stderr.writeln(error.message);
      return exitUsage;
    } on ArgumentError catch (error) {
      stderr.writeln(error.message?.toString() ?? error.toString());
      return exitUsage;
    } catch (error) {
      // Unknown fault: surface it and map to the ADS/protocol exit code.
      stderr.writeln('error: $error');
      return exitAdsError;
    }
  }
}
