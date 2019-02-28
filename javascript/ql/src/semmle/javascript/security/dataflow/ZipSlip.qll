/**
 * Provides a taint tracking configuration for reasoning about unsafe zip extraction.
 */

import javascript

module ZipSlip {
  /**
   * A data flow source for unsafe zip extraction.
   */
  abstract class Source extends DataFlow::Node { }

  /**
   * A data flow sink for unsafe zip extraction.
   */
  abstract class Sink extends DataFlow::Node { }

  /**
   * A sanitizer guard for unsafe zip extraction.
   */
  abstract class SanitizerGuard extends TaintTracking::SanitizerGuardNode, DataFlow::ValueNode { }

  /** A taint tracking configuration for unsafe zip extraction. */
  class Configuration extends TaintTracking::Configuration {
    Configuration() { this = "ZipSlip" }

    override predicate isSource(DataFlow::Node source) { source instanceof Source }

    override predicate isSink(DataFlow::Node sink) { sink instanceof Sink }

    override predicate isSanitizerGuard(TaintTracking::SanitizerGuardNode nd) {
      nd instanceof SanitizerGuard
    }
  }

  /**
   * Gets a node that can be a parsed zip archive.
   */
  private DataFlow::SourceNode parsedArchive() {
    result = DataFlow::moduleImport("unzip").getAMemberCall("Parse")
    or
    // `streamProducer.pipe(unzip.Parse())` is a typical (but not
    // universal) pattern when using nodejs streams, whose return
    // value is the parsed stream.
    exists(DataFlow::MethodCallNode pipe |
      pipe = result and
      pipe.getMethodName() = "pipe" and
      parsedArchive().flowsTo(pipe.getArgument(0))
    )
  }

  /** A zip archive entry path access, as a source for unsafe zip extraction. */
  class UnzipEntrySource extends Source {
    // For example, in
    // ```javascript
    // const unzip = require('unzip');
    //
    // fs.createReadStream('archive.zip')
    //   .pipe(unzip.Parse())
    //   .on('entry', entry => {
    //      const path = entry.path;
    //   });
    // ```
    // there is an `UnzipEntrySource` node corresponding to
    // the expression `entry.path`.
    UnzipEntrySource() {
      exists(DataFlow::CallNode cn |
        cn = parsedArchive().getAMemberCall("on") and
        cn.getArgument(0).mayHaveStringValue("entry") and
        this = cn.getCallback(1)
        .getParameter(0)
        .getAPropertyRead("path"))
    }
  }

  /** A call to `fs.createWriteStream`, as a sink for unsafe zip extraction. */
  class CreateWriteStreamSink extends Sink {
    CreateWriteStreamSink() {
      // This is not covered by `FileSystemWriteSink`, because it is
      // required that a write actually takes place to the stream.
      // However, we want to consider even the bare `createWriteStream`
      // to be a zipslip vulnerability since it may truncate an
      // existing file.
      this = DataFlow::moduleImport("fs").getAMemberCall("createWriteStream").getArgument(0)
    }
  }

  /** A file path of a file write, as a sink for unsafe zip extraction. */
  class FileSystemWriteSink extends Sink {
    FileSystemWriteSink() { exists(FileSystemWriteAccess fsw | fsw.getAPathArgument() = this) }
  }

  /**
   * Gets a string which is sufficient to exclude to make
   * a filepath definitely not refer to parent directories.
   */
  private string getAParentDirName() { result = ".." or result = "../" }

  /** A check that a path string does not include '..' */
  class NoParentDirSanitizerGuard extends SanitizerGuard {
    StringOps::Includes incl;

    NoParentDirSanitizerGuard() { this = incl }

    override predicate sanitizes(boolean outcome, Expr e) {
      incl.getPolarity().booleanNot() = outcome and
      incl.getBaseString().asExpr() = e and
      incl.getSubstring().mayHaveStringValue(getAParentDirName())
    }
  }
}
