import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:enough_mail/codecs/date_codec.dart';
import 'package:enough_mail/codecs/mail_codec.dart';
import 'package:enough_mail/enough_mail.dart';
import 'package:enough_mail/mail_address.dart';
import 'package:enough_mail/mail_conventions.dart';
import 'package:enough_mail/media_type.dart';
import 'package:enough_mail/mime_message.dart';
import 'package:enough_mail/mime_data.dart';
import 'package:intl/intl.dart';

/// The `transfer-encoding` used for encoding 8bit data if necessary
enum TransferEncoding {
  /// this mime message/part only consists of 7bit data, e.g. ASCII text
  sevenBit,

  /// actually daring to transfer 8bit as it is, e.g. UTF8
  eightBit,

  /// Quoted-printable is somewhat human readable
  quotedPrintable,

  /// base64 encoding is used to transfer binary data
  base64,

  /// the automatic options tries to find the best solution, ie `7bit` for ASCII texts, `quoted-printable` for 8bit texts and `base64` for binaries.
  automatic
}

/// The used character set
enum CharacterSet { ascii, utf8, latin1 }

/// The recipient
enum RecipientGroup { to, cc, bcc }

/// Information about a file that is attached
class AttachmentInfo {
  final String? name;
  final int? size;
  final MediaType mediaType;
  final ContentDisposition? contentDisposition;
  final File? file;
  final Uint8List? data;
  final PartBuilder part;
  AttachmentInfo(this.file, this.mediaType, this.name, this.size,
      this.contentDisposition, this.data, this.part);
}

/// Allows to configure a mime part
class PartBuilder {
  String? text;
  TransferEncoding transferEncoding;
  CharacterSet? characterSet;
  ContentTypeHeader? contentType;

  final attachments = <AttachmentInfo>[];
  bool get hasAttachments => attachments.isNotEmpty;

  final MimePart _part;
  List<PartBuilder>? _children;

  ContentDispositionHeader? contentDisposition;

  PartBuilder(
    MimePart mimePart, {
    this.text,
    this.transferEncoding = TransferEncoding.automatic,
    this.characterSet,
    this.contentType,
  }) : _part = mimePart;

  void _copy(MimePart originalPart) {
    contentType = originalPart.getHeaderContentType();

    if (originalPart.isTextMediaType()) {
      text = originalPart.decodeContentText();
    } else if (originalPart.parts == null) {
      _part.mimeData = originalPart.mimeData;
    }
    final parts = originalPart.parts;
    if (parts != null) {
      for (final part in parts) {
        final childDisposition = part.getHeaderContentDisposition();
        final childBuilder = addPart(
            disposition: childDisposition, mediaSubtype: part.mediaType.sub);
        if (childDisposition?.disposition == ContentDisposition.attachment) {
          final info = AttachmentInfo(
              null,
              part.mediaType,
              part.decodeFileName(),
              null,
              ContentDisposition.attachment,
              part.decodeContentBinary(),
              this);
          attachments.add(info);
        }
        childBuilder._copy(part);
      }
    }
  }

  /// Creates the content-type based on the specified [mediaType].
  ///
  /// Optionally you can specify the [characterSet], [multiPartBoundary], [name] or other [parameters].
  void setContentType(MediaType mediaType,
      {CharacterSet? characterSet,
      String? multiPartBoundary,
      String? name,
      Map<String, String>? parameters}) {
    if (mediaType.isMultipart && multiPartBoundary == null) {
      multiPartBoundary = MessageBuilder.createRandomId();
    }
    contentType = ContentTypeHeader.from(mediaType,
        charset: mediaType.top == MediaToptype.text
            ? MessageBuilder.getCharacterSetName(characterSet)
            : null,
        boundary: multiPartBoundary);
    if (name != null) {
      contentType!.parameters['name'] = '"$name"';
    }
    if (parameters?.isNotEmpty ?? false) {
      contentType!.parameters.addAll(parameters!);
    }
  }

  /// Adds a text part to this message with the specified [text].
  ///
  /// Specify the optional [mediaType], in case this is not a `text/plain` message
  /// and the [characterSet] in case it is not ASCII.
  /// Optionally specify the content disposition with [disposition].
  /// Optionally set [insert] to true to prepend and not append the part.
  /// Optionally specify the [transferEncoding] which detaults to `TransferEncoding.automatic`.
  PartBuilder addText(String text,
      {MediaType? mediaType,
      TransferEncoding transferEncoding = TransferEncoding.automatic,
      CharacterSet characterSet = CharacterSet.utf8,
      ContentDispositionHeader? disposition,
      bool insert = false}) {
    mediaType ??= MediaType.fromSubtype(MediaSubtype.textPlain);
    var child = addPart(insert: insert);
    child.setContentType(mediaType, characterSet: characterSet);
    child.transferEncoding = transferEncoding;
    child.contentDisposition = disposition;
    child.text = text;
    return child;
  }

  /// Adds a plain text part
  ///
  /// Compare `addText()` for details.
  PartBuilder addTextPlain(String text,
      {TransferEncoding transferEncoding = TransferEncoding.automatic,
      CharacterSet characterSet = CharacterSet.utf8,
      ContentDispositionHeader? disposition,
      bool insert = false}) {
    return addText(text,
        transferEncoding: transferEncoding,
        characterSet: characterSet,
        disposition: disposition,
        insert: insert);
  }

  /// Adds a HTML text part
  ///
  /// Compare `addText()` for details.
  PartBuilder addTextHtml(String text,
      {TransferEncoding transferEncoding = TransferEncoding.automatic,
      CharacterSet characterSet = CharacterSet.utf8,
      ContentDispositionHeader? disposition,
      bool insert = false}) {
    return addText(text,
        mediaType: MediaType.fromSubtype(MediaSubtype.textHtml),
        transferEncoding: transferEncoding,
        characterSet: characterSet,
        disposition: disposition,
        insert: insert);
  }

  /// Adds a new part
  ///
  /// Specifiy the optional [disposition] in case you want to specify the content-disposition
  /// Optionally specify the [mimePart], if it is already known
  /// Optionally specify the [mediaSubtype], e.g. `MediaSubtype.multipartAlternative`
  /// Optionally set [insert] to `true` to prepend and not append the part.
  PartBuilder addPart({
    ContentDispositionHeader? disposition,
    MimePart? mimePart,
    MediaSubtype? mediaSubtype,
    bool insert = false,
  }) {
    final addAttachmentInfo = (mimePart != null &&
        mimePart.getHeaderContentDisposition()?.disposition ==
            ContentDisposition.attachment);
    mimePart ??= MimePart();
    final childBuilder = PartBuilder(mimePart);
    if (mediaSubtype != null) {
      childBuilder.setContentType(MediaType.fromSubtype(mediaSubtype));
    } else if (mimePart.getHeaderContentType() != null) {
      childBuilder.contentType = mimePart.getHeaderContentType();
    }
    _children ??= <PartBuilder>[];
    if (insert) {
      _part.insertPart(mimePart);
      _children!.insert(0, childBuilder);
    } else {
      _part.addPart(mimePart);
      _children!.add(childBuilder);
    }
    disposition ??= mimePart.getHeaderContentDisposition();
    childBuilder.contentDisposition = disposition;
    if (mimePart.isTextMediaType()) {
      childBuilder.text = mimePart.decodeContentText();
    }
    if (addAttachmentInfo) {
      final info = AttachmentInfo(
          null,
          mimePart.mediaType,
          mimePart.decodeFileName(),
          disposition!.size,
          disposition.disposition,
          mimePart.decodeContentBinary(),
          childBuilder);
      attachments.add(info);
    }

    return childBuilder;
  }

  /// Retrieves the first builder with a text/plain part.
  ///
  /// Note that only this builder and direct children are queried.
  PartBuilder? getTextPlainPart() {
    return getPart(MediaSubtype.textPlain);
  }

  /// Retrieves the first builder with a text/plain part.
  ///
  /// Note that only this builder and direct children are queried.
  PartBuilder? getTextHtmlPart() {
    return getPart(MediaSubtype.textHtml);
  }

  /// Retrieves the first builder with the specified [mediaSubtype].
  ///
  /// Note that only this builder and direct children are queried.
  PartBuilder? getPart(MediaSubtype mediaSubtype) {
    final isPlainText = (mediaSubtype == MediaSubtype.textPlain);
    if (_children?.isEmpty ?? true) {
      if (contentType?.mediaType.sub == mediaSubtype ||
          (isPlainText && contentType == null)) {
        return this;
      }
      return null;
    }
    for (final child in _children!) {
      final matchingPart = child.getPart(mediaSubtype);
      if (matchingPart != null) {
        return matchingPart;
      }
    }
    return null;
  }

  /// Removes the specified attachment [info]
  void removeAttachment(AttachmentInfo info) {
    attachments.remove(info);
    removePart(info.part);
  }

  /// Removes the specified part [childBuilder]
  void removePart(PartBuilder childBuilder) {
    _part.parts!.remove(childBuilder._part);
    _children!.remove(childBuilder);
  }

  /// Adds the [file] part asyncronously.
  ///
  /// [file] The file that should be added.
  /// [mediaType] The media type of the file.
  /// Specify the optional content [disposition] element, if it should not be populated automatically.
  /// This will add an `AttachmentInfo` element to the `attachments` list of this builder.
  Future<PartBuilder> addFile(File file, MediaType mediaType,
      {ContentDispositionHeader? disposition}) async {
    disposition ??=
        ContentDispositionHeader.from(ContentDisposition.attachment);
    disposition.filename ??= _getFileName(file);
    disposition.size ??= await file.length();
    disposition.modificationDate ??= await file.lastModified();
    final child = addPart(disposition: disposition);
    final data = await file.readAsBytes();
    child.transferEncoding = TransferEncoding.base64;
    final info = AttachmentInfo(file, mediaType, disposition.filename,
        disposition.size, disposition.disposition, data, child);
    attachments.add(info);
    child.setContentType(mediaType, name: disposition.filename);
    child._part.mimeData =
        TextMimeData(MailCodec.base64.encodeData(data), false);
    ;
    return child;
  }

  String _getFileName(File file) {
    var name = file.path;
    var lastPathSeparator =
        math.max(name.lastIndexOf('/'), name.lastIndexOf('\\'));
    if (lastPathSeparator != -1 && lastPathSeparator != name.length - 1) {
      name = name.substring(lastPathSeparator + 1);
    }
    return name;
  }

  /// Adds a binary data part with the given [data] and optional [filename].
  ///
  /// [mediaType] The media type of the file.
  /// Specify the optional content [disposition] element, if it should not be populated automatically.
  PartBuilder addBinary(Uint8List data, MediaType mediaType,
      {TransferEncoding transferEncoding = TransferEncoding.base64,
      ContentDispositionHeader? disposition,
      String? filename}) {
    disposition ??= ContentDispositionHeader.from(ContentDisposition.attachment,
        filename: filename, size: data.length);
    var child = addPart(disposition: disposition);
    child.transferEncoding = TransferEncoding.base64;

    child.setContentType(mediaType, name: filename);
    final info = AttachmentInfo(null, mediaType, filename, data.length,
        disposition.disposition, data, child);
    attachments.add(info);
    child._part.mimeData =
        TextMimeData(MailCodec.base64.encodeData(data), false);
    return child;
  }

  /// Adds a header with the specified [name] and [value].
  /// Compare [MailConventions] for common header names.
  /// Set [encode] to true to encode the header value in quoted printable format.
  void addHeader(String name, String value, {bool encode = false}) {
    if (encode) {
      value = MailCodec.quotedPrintable.encodeHeader(value);
    }
    _part.addHeader(name, value);
  }

  /// Sets a header with the specified [name] and [value], replacing any previous header with the same [name].
  /// Compare [MailConventions] for common header names.
  /// Set [encode] to true to encode the header value in quoted printable format.
  void setHeader(String name, String? value, {bool encode = false}) {
    if (encode) {
      value = MailCodec.quotedPrintable.encodeHeader(value!);
    }
    _part.setHeader(name, value);
  }

  /// Adds another header with the specified [name] with the given mail [addresses] as its value
  void addMailAddressHeader(String name, List<MailAddress> addresses) {
    addHeader(name, addresses.map((a) => a.encode()).join('; '));
  }

  /// Adds the header with the specified [name] with the given mail [addresses] as its value
  void setMailAddressHeader(String name, List<MailAddress> addresses) {
    setHeader(name, addresses.map((a) => a.encode()).join('; '));
  }

  void _buildPart() {
    var partTransferEncoding = transferEncoding;
    if (partTransferEncoding == TransferEncoding.automatic) {
      final messageText = text;
      if (messageText != null &&
          (contentType == null || contentType!.mediaType.isText)) {
        partTransferEncoding =
            MessageBuilder._contains8BitCharacters(messageText)
                ? TransferEncoding.quotedPrintable
                : TransferEncoding.sevenBit;
      } else {
        partTransferEncoding = TransferEncoding.base64;
      }
      transferEncoding = partTransferEncoding;
    }
    if (contentType == null) {
      if (attachments.isNotEmpty) {
        setContentType(MediaType.fromSubtype(MediaSubtype.multipartMixed),
            multiPartBoundary: MessageBuilder.createRandomId());
      } else if (_children == null || _children!.isEmpty) {
        setContentType(MediaType.fromSubtype(MediaSubtype.textPlain));
      } else {
        setContentType(MediaType.fromSubtype(MediaSubtype.multipartMixed),
            multiPartBoundary: MessageBuilder.createRandomId());
      }
    }
    if (contentType != null) {
      if (attachments.isNotEmpty && contentType!.boundary == null) {
        contentType!.boundary = MessageBuilder.createRandomId();
      }
      setHeader(MailConventions.headerContentType, contentType!.render());
    }

    setHeader(MailConventions.headerContentTransferEncoding,
        MessageBuilder.getContentTransferEncodingName(partTransferEncoding));
    if (contentDisposition != null) {
      setHeader(MailConventions.headerContentDisposition,
          contentDisposition!.render());
    }
    // build body:
    if (text != null && (_part.parts?.isEmpty ?? true)) {
      _part.mimeData = TextMimeData(
          MessageBuilder.encodeText(
              text!, transferEncoding, characterSet ?? CharacterSet.utf8),
          false);
      if (contentType == null) {
        setHeader(MailConventions.headerContentType,
            'text/plain; charset="${MessageBuilder.getCharacterSetName(characterSet)}"');
      }
    }
    if (_children != null && _children!.isNotEmpty) {
      for (var child in _children!) {
        child._buildPart();
      }
    }
  }
}

/// Simplifies creating mime messages for sending or storing.
class MessageBuilder extends PartBuilder {
  late MimeMessage _message;

  /// List of senders, typically this is only one sender
  List<MailAddress>? from;

  /// One sender in case there are different `from` senders
  MailAddress? sender;

  /// `to` recpients
  List<MailAddress>? to;

  /// `cc` recpients
  List<MailAddress>? cc;

  /// `bcc` recpients
  List<MailAddress>? bcc;

  /// Message subject
  String? subject;

  /// Message date
  DateTime? date;

  /// ID of the message
  String? messageId;

  /// Reference to original message
  MimeMessage? originalMessage;

  /// Set to `true` in case only the last replied to message should be referenced. Useful for long threads.
  bool replyToSimplifyReferences = false;

  /// Set to `true` to set chat headers
  bool isChat = false;

  /// Specify in case this is a chat group discussion
  String? chatGroupId;

  /// Creates a new message builder and populates it with the optional data.
  ///
  /// Set the plain text part with [text] encoded with [encoding] using the given [characterSet].
  /// You can also set the complete [contentType] and specify a [transferEncoding].
  /// You can also specify the [base] message which will be used to populate this message builder. This is useful to continue editing a /Draft message, for example.
  MessageBuilder({
    String? text,
    TransferEncoding transferEncoding = TransferEncoding.automatic,
    CharacterSet? characterSet,
    ContentTypeHeader? contentType,
  }) : super(
          MimeMessage(),
          text: text,
          transferEncoding: transferEncoding,
          characterSet: characterSet,
          contentType: contentType,
        ) {
    _message = _part as MimeMessage;
  }

  @override
  void _copy(MimePart originalPart) {
    final base = originalMessage as MimeMessage;
    characterSet = CharacterSet.utf8;
    to = base.to;
    cc = base.cc;
    bcc = base.bcc;
    subject = base.decodeSubject();

    super._copy(originalPart);
  }

  /// Adds a [recipient].
  ///
  /// Specify the [group] in case the recipient should not be added to the 'To' group.
  /// Compare [removeRecipient()] and [clearRecipients()].
  void addRecipient(MailAddress recipient,
      {RecipientGroup group = RecipientGroup.to}) {
    switch (group) {
      case RecipientGroup.to:
        to ??= <MailAddress>[];
        to!.add(recipient);
        break;
      case RecipientGroup.cc:
        cc ??= <MailAddress>[];
        cc!.add(recipient);
        break;
      case RecipientGroup.bcc:
        bcc ??= <MailAddress>[];
        bcc!.add(recipient);
        break;
    }
  }

  /// Removes the specified [recipient] from To/Cc/Bcc fields.
  ///
  /// Compare [addRecipient()] and [clearRecipients()].
  void removeRecipient(MailAddress recipient) {
    if (to != null) {
      to!.remove(recipient);
    }
    if (cc != null) {
      cc!.remove(recipient);
    }
    if (bcc != null) {
      bcc!.remove(recipient);
    }
  }

  /// Removes all recipients from this message.
  ///
  /// Compare [removeRecipient()] and [addRecipient()].
  void clearRecipients() {
    to = null;
    cc = null;
    bcc = null;
  }

  TransferEncoding setRecommendedTextEncoding(bool supports8BitMessages) {
    var recommendedEncoding = TransferEncoding.quotedPrintable;
    final textHtml = getTextHtmlPart();
    final textPlain = getTextPlainPart();
    if (!supports8BitMessages) {
      if (_contains8BitCharacters(text) ||
          _contains8BitCharacters(textPlain?.text) ||
          _contains8BitCharacters(textHtml?.text)) {
        recommendedEncoding = TransferEncoding.quotedPrintable;
      } else {
        recommendedEncoding = TransferEncoding.sevenBit;
      }
    }
    transferEncoding = recommendedEncoding;
    textHtml?.transferEncoding = recommendedEncoding;
    textPlain?.transferEncoding = recommendedEncoding;
    return recommendedEncoding;
  }

  static bool _contains8BitCharacters(String? text) {
    if (text == null) {
      return false;
    }
    return text.runes.any((rune) => rune >= 127);
  }

  /// Creates the mime message based on the previous input.
  MimeMessage buildMimeMessage() {
    // there are not mandatory fields required in case only a Draft message should be stored, for example

    // set default values for standard headers:
    date ??= DateTime.now();
    messageId ??= createMessageId(
        (from?.isEmpty ?? true) ? 'enough.de' : from!.first.hostName,
        isChat: isChat,
        chatGroupId: chatGroupId);
    if (subject == null && originalMessage != null) {
      final originalSubject = originalMessage!.decodeSubject();
      if (originalSubject != null) {
        subject = createReplySubject(originalSubject);
      }
    }
    if (from != null) {
      setMailAddressHeader('From', from!);
    }
    if (sender != null) {
      setMailAddressHeader('Sender', [sender!]);
    }
    var addresses = to;
    if (addresses != null && addresses.isNotEmpty) {
      setMailAddressHeader('To', addresses);
    }
    addresses = cc;
    if (addresses != null && addresses.isNotEmpty) {
      setMailAddressHeader('Cc', addresses);
    }
    addresses = bcc;
    if (addresses != null && addresses.isNotEmpty) {
      setMailAddressHeader('Bcc', addresses);
    }
    setHeader('Date', DateCodec.encodeDate(date!));
    setHeader('Message-Id', messageId);
    if (isChat) {
      setHeader('Chat-Version', '1.0');
    }
    if (subject != null) {
      setHeader('Subject', subject, encode: true);
    }
    setHeader(MailConventions.headerMimeVersion, '1.0');
    final original = originalMessage;
    if (original != null) {
      final originalMessageId = original.getHeaderValue('message-id');
      setHeader(MailConventions.headerInReplyTo, originalMessageId);
      final originalReferences = original.getHeaderValue('references');
      final references = originalReferences == null
          ? originalMessageId
          : replyToSimplifyReferences
              ? originalReferences
              : originalReferences + ' ' + originalMessageId!;
      setHeader(MailConventions.headerReferences, references);
    }
    if (text != null && attachments.isNotEmpty) {
      addTextPlain(text!, transferEncoding: transferEncoding, insert: true);
    }
    _buildPart();
    return _message;
  }

  /// Creates a text message.
  ///
  /// [from] the mandatory originator of the message
  /// [to] the mandatory list of recipients
  /// [text] the mandatory content of the message
  /// [cc] the optional "carbon copy" recipients that are informed about this message
  /// [bcc] the optional "blind carbon copy" recipients that should receive the message without others being able to see those recipients
  /// [subject] the optional subject of the message, if null and a [replyToMessage] is specified, then the subject of that message is being re-used.
  /// [date] the optional date of the message, is set to DateTime.now() by default
  /// [replyToMessage] is the message that this message is a reply to
  /// Set the optional [replyToSimplifyReferences] parameter to true in case only the root message-ID should be repeated instead of all references as calculated from the [replyToMessage],
  /// [messageId] the optional custom message ID
  /// Set the optional [isChat] to true in case a COI-compliant message ID should be generated, in case of a group message also specify the [chatGroupId].
  /// [chatGroupId] the optional ID of the chat group in case the message-ID should be generated.
  /// [characterSet] the optional character set, defaults to UTF8
  /// [encoding] the otional message encoding, defaults to 8bit
  static MimeMessage? buildSimpleTextMessage(
      MailAddress from, List<MailAddress> to, String text,
      {List<MailAddress>? cc,
      List<MailAddress>? bcc,
      String? subject,
      DateTime? date,
      MimeMessage? replyToMessage,
      bool replyToSimplifyReferences = false,
      String? messageId,
      bool isChat = false,
      String? chatGroupId,
      CharacterSet characterSet = CharacterSet.utf8,
      TransferEncoding transferEncoding = TransferEncoding.quotedPrintable}) {
    var builder = MessageBuilder()
      ..from = [from]
      ..to = to
      ..subject = subject
      ..text = text
      ..cc = cc
      ..bcc = bcc
      ..date = date
      ..originalMessage = replyToMessage
      ..replyToSimplifyReferences = replyToSimplifyReferences
      ..messageId = messageId
      ..isChat = isChat
      ..chatGroupId = chatGroupId
      ..characterSet = characterSet
      ..transferEncoding = transferEncoding;

    return builder.buildMimeMessage();
  }

  static TransferEncoding _getTransferEncoding(MimeMessage originalMessage) {
    final originalTransferEncoding = originalMessage
        .getHeaderValue(MailConventions.headerContentTransferEncoding);
    return originalTransferEncoding == null
        ? TransferEncoding.automatic
        : fromContentTransferEncodingName(originalTransferEncoding);
  }

  /// Prepares a message builder from the specified [draft] mime message.
  static MessageBuilder prepareFromDraft(MimeMessage draft) {
    final builder = MessageBuilder()..originalMessage = draft;
    builder._copy(draft);
    return builder;
  }

  /// Prepares to forward the given [originalMessage].
  /// Optionallyspecify the sending user with [from].
  /// You can also specify a custom [forwardHeaderTemplate]. The default `MailConventions.defaultForwardHeaderTemplate` contains the metadata information about the original message including subject, to, cc, date.
  /// Specify the [defaultForwardAbbreviation] if not `Fwd` should be used at the beginning of the subject to indicate an reply.
  /// Set [quoteMessage] to `false` when you plan to quote text yourself, e.g. using the `enough_mail_html`'s package `quoteToHtml()` method.
  static MessageBuilder prepareForwardMessage(MimeMessage originalMessage,
      {MailAddress? from,
      String forwardHeaderTemplate =
          MailConventions.defaultForwardHeaderTemplate,
      String defaultForwardAbbreviation =
          MailConventions.defaultForwardAbbreviation,
      bool quoteMessage = true}) {
    String subject;
    var originalSubject = originalMessage.decodeSubject();
    if (originalSubject != null) {
      subject = createForwardSubject(originalSubject,
          defaultForwardAbbreviation: defaultForwardAbbreviation);
    } else {
      subject = defaultForwardAbbreviation;
    }

    final builder = MessageBuilder()
      ..subject = subject
      ..contentType = originalMessage.getHeaderContentType()
      ..transferEncoding = _getTransferEncoding(originalMessage)
      ..originalMessage = originalMessage;
    if (from != null) {
      builder.from = [from];
    }
    if (quoteMessage) {
      final forwardHeader =
          fillTemplate(forwardHeaderTemplate, originalMessage);
      if (originalMessage.parts?.isNotEmpty ?? false) {
        var processedTextPlainPart = false;
        var processedTextHtmlPart = false;
        for (final part in originalMessage.parts!) {
          builder.contentType = originalMessage.getHeaderContentType();
          if (part.isTextMediaType()) {
            if (!processedTextPlainPart &&
                part.mediaType.sub == MediaSubtype.textPlain) {
              final plainText = part.decodeContentText();
              final quotedPlainText = quotePlainText(forwardHeader, plainText);
              builder.addTextPlain(quotedPlainText);
              processedTextPlainPart = true;
              continue;
            }
            if (!processedTextHtmlPart &&
                part.mediaType.sub == MediaSubtype.textHtml) {
              final decodedHtml = part.decodeContentText() ?? '';
              final quotedHtml = '<br/><blockquote>' +
                  forwardHeader.split('\r\n').join('<br/>\r\n') +
                  '<br/>\r\n' +
                  decodedHtml +
                  '</blockquote>';
              builder.addTextHtml(quotedHtml);
              processedTextHtmlPart = true;
              continue;
            }
          }
          builder.addPart(mimePart: part);
        }
      } else {
        // no parts, this is most likely a plain text message:
        if (originalMessage.isTextPlainMessage()) {
          final plainText = originalMessage.decodeContentText();
          final quotedPlainText = quotePlainText(forwardHeader, plainText);
          builder.text = quotedPlainText;
        } else {
          //TODO check if there is anything else to quote
        }
      }
    } else {
      // do not quote message but forward attachments
      final infos = originalMessage.findContentInfo();
      for (final info in infos) {
        final part = originalMessage.getPart(info.fetchId);
        if (part != null) {
          builder.addPart(mimePart: part);
        }
      }
    }

    return builder;
  }

  /// Quotes the given plain text [header] and [text].
  static String quotePlainText(final String header, final String? text) {
    if (text == null) {
      return '>\r\n';
    }
    return '>' +
        header.split('\r\n').join('\r\n>') +
        '\r\n>' +
        text.split('\r\n').join('\r\n>');
  }

  /// Prepares to create a reply to the given [originalMessage] to be send by the user specifed in [from].
  ///
  /// Set [replyAll] to false in case the reply should only be done to the sender of the message and not to other recipients
  /// Set [quoteOriginalText] to true in case the original plain and html texts should be added to the generated message.
  /// Set [preferPlainText] and [quoteOriginalText] to true in case only plain text should be quoted.
  /// You can also specify a custom [replyHeaderTemplate], which is only used when [quoteOriginalText] has been set to true. The default replyHeaderTemplate is 'On <date> <from> wrote:'.
  /// Set [replyToSimplifyReferences] to true if the References field should not contain the references of all messages in this thread.
  /// Specify the [defaultReplyAbbreviation] if not 'Re' should be used at the beginning of the subject to indicate an reply.
  /// Specify the known [aliases] of the recipient, so that alias addreses are not added as recipients and a detected alias is used instead of the [from] address in that case.
  /// Set [handlePlusAliases] to true in case plus aliases like `email+alias@domain.com` should be detected and used.
  static MessageBuilder prepareReplyToMessage(
      MimeMessage originalMessage, MailAddress from,
      {bool replyAll = true,
      bool quoteOriginalText = false,
      bool preferPlainText = false,
      String replyHeaderTemplate = MailConventions.defaultReplyHeaderTemplate,
      String defaultReplyAbbreviation =
          MailConventions.defaultReplyAbbreviation,
      bool replyToSimplifyReferences = false,
      List<MailAddress>? aliases,
      bool handlePlusAliases = false}) {
    String? subject;
    final originalSubject = originalMessage.decodeSubject();
    if (originalSubject != null) {
      subject = createReplySubject(originalSubject,
          defaultReplyAbbreviation: defaultReplyAbbreviation);
    }
    var to = originalMessage.to ?? [];
    var cc = originalMessage.cc;
    final replyTo = originalMessage.decodeSender();
    List<MailAddress> senders;
    if (aliases?.isNotEmpty ?? false) {
      senders = [from, ...aliases!];
    } else {
      senders = [from];
    }
    var newSender = MailAddress.getMatch(senders, replyTo,
        handlePlusAliases: handlePlusAliases,
        removeMatch: true,
        useMatchPersonalName: true);
    newSender ??= MailAddress.getMatch(senders, to,
        handlePlusAliases: handlePlusAliases, removeMatch: true);
    newSender ??= MailAddress.getMatch(senders, cc,
        handlePlusAliases: handlePlusAliases, removeMatch: true);
    if (newSender != null) {
      from = newSender;
    }
    if (replyAll) {
      to.insertAll(0, replyTo);
    } else {
      if (replyTo.isNotEmpty) {
        to = [...replyTo];
      }
      cc = null;
    }
    final builder = MessageBuilder()
      ..subject = subject
      ..originalMessage = originalMessage
      ..from = [from]
      ..to = to
      ..cc = cc
      ..replyToSimplifyReferences = replyToSimplifyReferences;

    if (quoteOriginalText) {
      final replyHeader = fillTemplate(replyHeaderTemplate, originalMessage);

      final plainText = originalMessage.decodeTextPlainPart();
      final quotedPlainText = quotePlainText(replyHeader, plainText);
      final decodedHtml = originalMessage.decodeTextHtmlPart();
      if (preferPlainText || decodedHtml == null) {
        builder.text = quotedPlainText;
      } else {
        builder.setContentType(
            MediaType.fromSubtype(MediaSubtype.multipartAlternative));
        builder.addTextPlain(quotedPlainText);
        final quotedHtml = '<blockquote><br/>' +
            replyHeader +
            '<br/>' +
            decodedHtml +
            '</blockquote>';
        builder.addTextHtml(quotedHtml);
      }
    }
    return builder;
  }

  /// Convenience method for initiating a multipart/alternative message
  ///
  /// In case you want to use 7bit instead of the default 8bit content transfer encoding, specify the optional [encoding].
  /// You can also create a new MessageBuilder and call [setContentType()] with the same effect when using the multipart/alternative media subtype.
  static MessageBuilder prepareMultipartAlternativeMessage(
      {TransferEncoding transferEncoding = TransferEncoding.eightBit}) {
    return prepareMessageWithMediaType(MediaSubtype.multipartAlternative,
        transferEncoding: transferEncoding);
  }

  /// Convenience method for initiating a multipart/mixed message
  ///
  /// In case you want to use 7bit instead of the default 8bit content transfer encoding, specify the optional [encoding].
  /// You can also create a new MessageBuilder and call [setContentType()] with the same effect when using the multipart/mixed media subtype.
  static MessageBuilder prepareMultipartMixedMessage(
      {TransferEncoding transferEncoding = TransferEncoding.eightBit}) {
    return prepareMessageWithMediaType(MediaSubtype.multipartMixed,
        transferEncoding: transferEncoding);
  }

  /// Convenience method for initiating a message with the specified media [subtype]
  ///
  /// In case you want to use 7bit instead of the default 8bit content transfer encoding, specify the optional [encoding].
  /// You can also create a new MessageBuilder and call [setContentType()] with the same effect when using the identical media subtype.
  static MessageBuilder prepareMessageWithMediaType(MediaSubtype subtype,
      {TransferEncoding transferEncoding = TransferEncoding.eightBit}) {
    var mediaType = MediaType.fromSubtype(subtype);
    var builder = MessageBuilder()
      ..setContentType(mediaType)
      ..transferEncoding = transferEncoding;
    return builder;
  }

  /// Convenience method for creating a message based on a [mailto](https://tools.ietf.org/html/rfc6068) URI from the sender specified in [from].
  ///
  /// The following fields are supported:
  /// * mailto `to` recpient address(es)
  /// * `cc` - CC recipient address(es)
  /// * `subject` - the subject header field
  /// * `body` - the body header field
  /// * `in-reply-to` -  message ID to which the new message is a reply
  static MessageBuilder prepareMailtoBasedMessage(
      Uri mailto, MailAddress from) {
    final builder = MessageBuilder()
      ..from = [from]
      ..setContentType(MediaType.textPlain, characterSet: CharacterSet.utf8)
      ..transferEncoding = TransferEncoding.automatic;
    final to = <MailAddress>[];
    for (final value in mailto.pathSegments) {
      to.addAll(value.split(',').map((email) => MailAddress(null, email)));
    }
    final queryParameters = mailto.queryParameters;
    for (final key in queryParameters.keys) {
      final value = queryParameters[key];
      switch (key.toLowerCase()) {
        case 'subject':
          builder.subject = value;
          break;
        case 'to':
          to.addAll(value!.split(',').map((email) => MailAddress(null, email)));
          break;
        case 'cc':
          builder.cc = value!
              .split(',')
              .map((email) => MailAddress(null, email))
              .toList();
          break;
        case 'body':
          builder.text = value;
          break;
        case 'in-reply-to':
          builder.setHeader(key, value);
          break;
        default:
          print('unsuported mailto parameter $key=$value');
      }
    }
    builder.to = to;
    return builder;
  }

  /// Generates a message ID
  ///
  /// [hostName] the domain like 'example.com'
  /// Set the optional [isChat] to true in case a COI-compliant message ID should be generated, in case of a group message also specify the [chatGroupId].
  /// [chatGroupId] the optional ID of the chat group in case the message-ID should be generated.
  static String createMessageId(String? hostName,
      {bool isChat = false, String? chatGroupId}) {
    String id;
    var random = createRandomId();
    if (isChat) {
      if (chatGroupId != null && chatGroupId.isNotEmpty) {
        id = '<chat\$group.$chatGroupId.$random@$hostName>';
      } else {
        id = '<chat\$$random@$hostName>';
      }
    } else {
      id = '<$random@$hostName>';
    }
    return id;
  }

  /// Encodes the specified [text] with given [transferEncoding].
  ///
  /// Specify the [characterSet] when a different character set than UTF-8 should be used.
  static String encodeText(String text, TransferEncoding transferEncoding,
      [CharacterSet characterSet = CharacterSet.utf8]) {
    switch (transferEncoding) {
      case TransferEncoding.quotedPrintable:
        return MailCodec.quotedPrintable
            .encodeText(text, codec: getCodec(characterSet));
      case TransferEncoding.base64:
        return MailCodec.base64.encodeText(text, codec: getCodec(characterSet));
      default:
        return MailCodec.wrapText(text, wrapAtWordBoundary: true);
    }
  }

  /// Rerieves the codec for the specified [characterSet].
  static Codec getCodec(CharacterSet? characterSet) {
    switch (characterSet) {
      case null:
        return utf8;
      case CharacterSet.ascii:
        return ascii;
      case CharacterSet.utf8:
        return utf8;
      case CharacterSet.latin1:
        return latin1;
    }
  }

  /// Encodes the specified header [value].
  ///
  /// Specify the [encoding] when not the default `quoted-printable` encoding should be used.
  static String encodeHeaderValue(String value,
      [TransferEncoding transferEncoding = TransferEncoding.quotedPrintable]) {
    switch (transferEncoding) {
      case TransferEncoding.quotedPrintable:
        return MailCodec.quotedPrintable.encodeHeader(value);
      case TransferEncoding.base64:
        return MailCodec.base64.encodeHeader(value);
      default:
        return value;
    }
  }

  /// Retrieves the name of the specified [characterSet].
  static String getCharacterSetName(CharacterSet? characterSet) {
    switch (characterSet) {
      case null:
        return 'utf-8';
      case CharacterSet.utf8:
        return 'utf-8';
      case CharacterSet.ascii:
        return 'ascii';
      case CharacterSet.latin1:
        return 'latin1';
    }
  }

  /// Retrieves the name of the specified [encoding].
  static String getContentTransferEncodingName(TransferEncoding encoding) {
    switch (encoding) {
      case TransferEncoding.sevenBit:
        return '7bit';
      case TransferEncoding.eightBit:
        return '8bit';
      case TransferEncoding.quotedPrintable:
        return 'quoted-printable';
      case TransferEncoding.base64:
        return 'base64';
      default:
        throw StateError('Unhandled transfer encoding: $encoding');
    }
  }

  static TransferEncoding fromContentTransferEncodingName(String name) {
    switch (name.toLowerCase()) {
      case '7bit':
        return TransferEncoding.sevenBit;
      case '8bit':
        return TransferEncoding.eightBit;
      case 'quoted-printable':
        return TransferEncoding.quotedPrintable;
      case 'base64':
        return TransferEncoding.base64;
    }
    return TransferEncoding.automatic;
  }

  /// Creates a subject based on the [originalSubject] taking mail conventions into account.
  ///
  /// Optionally specify the reply-indicator abbreviation by specifying [defaultReplyAbbreviation], which defaults to 'Re'.
  static String createReplySubject(String originalSubject,
      {String defaultReplyAbbreviation =
          MailConventions.defaultReplyAbbreviation}) {
    return _createSubject(originalSubject, defaultReplyAbbreviation,
        MailConventions.subjectReplyAbbreviations);
  }

  /// Creates a subject based on the [originalSubject] taking mail conventions into account.
  ///
  /// Optionally specify the forward-indicator abbreviation by specifying [defaultForwardAbbreviation], which defaults to 'Fwd'.
  static String createForwardSubject(String originalSubject,
      {String defaultForwardAbbreviation =
          MailConventions.defaultForwardAbbreviation}) {
    return _createSubject(originalSubject, defaultForwardAbbreviation,
        MailConventions.subjectForwardAbbreviations);
  }

  /// Creates a subject based on the [originalSubject] taking mail conventions into account.
  ///
  /// Optionally specify the reply-indicator abbreviation by specifying [defaultAbbreviation], which defaults to 'Re'.
  static String _createSubject(String originalSubject,
      String defaultAbbreviation, List<String> commonAbbreviations) {
    var colonIndex = originalSubject.indexOf(':');
    if (colonIndex != -1) {
      var start = originalSubject.substring(0, colonIndex);
      if (commonAbbreviations.contains(start)) {
        // the original subject already contains a common reply abbreviation, e.g. 'Re: bla'
        return originalSubject;
      }
      // some mail servers use rewrite rules to adapt the subject, e.g start each external messages with '[EXT]'
      var prefixStartIndex = originalSubject.indexOf('[');
      if (prefixStartIndex == 0) {
        var prefixEndIndex = originalSubject.indexOf(']');
        if (prefixEndIndex < colonIndex) {
          start = start.substring(prefixEndIndex + 1).trim();
          if (commonAbbreviations.contains(start)) {
            // the original subject already contains a common reply abbreviation, e.g. 'Re: bla'
            return originalSubject.substring(prefixEndIndex + 1).trim();
          }
        }
      }
    }
    return '$defaultAbbreviation: $originalSubject';
  }

  /// Creates a new randomized ID text.
  ///
  /// Specify [length] when a different length than 18 characters should be used.
  /// This can be used as a multipart boundary or a message-ID, for example.
  static String createRandomId({int length = 18}) {
    var characters =
        '0123456789_abcdefghijklmnopqrstuvwxyz-ABCDEFGHIJKLMNOPQRSTUVWXYZ';
    var characterRunes = characters.runes;
    var max = characters.length;
    var random = math.Random();
    var buffer = StringBuffer();
    for (var count = length; count > 0; count--) {
      var charIndex = random.nextInt(max);
      var rune = characterRunes.elementAt(charIndex);
      buffer.writeCharCode(rune);
    }
    return buffer.toString();
  }

  /// Fills the given [template] with values extracted from the provided [message].
  ///
  /// Currently the following templates are supported:
  ///  `<from>`: specifies the message sender (name plus email)
  ///  `<date>`: specifies the message date
  ///  `<to>`: the `to` recipients
  ///  `<cc>`: the `cc` recipients
  ///  `<subject>`: the subject of the message
  /// Note that for date formatting Dart's intl library is used: https://pub.dev/packages/intl
  /// You might want to specify the default locale by setting [Intl.defaultLocale] first.
  static String fillTemplate(String template, MimeMessage message) {
    final definedVariables = <String>[];
    var from = message.decodeHeaderMailAddressValue('sender');
    if (from?.isEmpty ?? true) {
      from = message.decodeHeaderMailAddressValue('from');
    }
    if (from?.isNotEmpty ?? false) {
      definedVariables.add('from');
      template = template.replaceAll('<from>', from!.first.toString());
    }
    final date = message.decodeHeaderDateValue('date');
    if (date != null) {
      definedVariables.add('date');
      final dateStr = DateFormat.yMd().add_jm().format(date);
      template = template.replaceAll('<date>', dateStr);
    }
    final to = message.to;
    if (to?.isNotEmpty ?? false) {
      definedVariables.add('to');
      template = template.replaceAll('<to>', _renderAddresses(to!));
    }
    final cc = message.cc;
    if (cc?.isNotEmpty ?? false) {
      definedVariables.add('cc');
      template = template.replaceAll('<cc>', _renderAddresses(cc!));
    }
    final subject = message.decodeSubject();
    if (subject != null) {
      definedVariables.add('subject');
      template = template.replaceAll('<subject>', subject);
    }
    // remove any undefined variables from template:
    final optionalInclusionsExpression = RegExp(r'\[\[\w+\s[\s\S]+?\]\]');
    RegExpMatch? match;
    while (
        (match = optionalInclusionsExpression.firstMatch(template)) != null) {
      final sequence = match!.group(0)!;
      //print('sequence=$sequence');
      final separatorIndex = sequence.indexOf(' ', 2);
      final name = sequence.substring(2, separatorIndex);
      var replacement = '';
      if (definedVariables.contains(name)) {
        replacement =
            sequence.substring(separatorIndex + 1, sequence.length - 2);
      }
      template = template.replaceAll(sequence, replacement);
    }
    return template;
  }

  static String _renderAddresses(List<MailAddress> addresses) {
    var buffer = StringBuffer();
    var addDelimiter = false;
    for (var address in addresses) {
      if (addDelimiter) {
        buffer.write('; ');
      }
      address.writeToStringBuffer(buffer);
      addDelimiter = true;
    }
    return buffer.toString();
  }
}
