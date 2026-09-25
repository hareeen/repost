import repost/r2/xml

// AWS CreateMultipartUpload sample response: https://docs.aws.amazon.com/AmazonS3/latest/API/API_CreateMultipartUpload.html
fn initiate_response() -> String {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  <> "<InitiateMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\n"
  <> "  <Bucket>amzn-s3-demo-bucket</Bucket>\n"
  <> "  <Key>example-object</Key>\n"
  <> "  <UploadId>VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA</UploadId>\n"
  <> "</InitiateMultipartUploadResult>"
}

// AWS CompleteMultipartUpload sample responses: https://docs.aws.amazon.com/AmazonS3/latest/API/API_CompleteMultipartUpload.html
fn complete_response() -> String {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  <> "<CompleteMultipartUploadResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\n"
  <> " <Location>http://amzn-s3-demo-bucket.s3.<Region>.amazonaws.com/Example-Object</Location>\n"
  <> " <Bucket>amzn-s3-demo-bucket</Bucket>\n"
  <> " <Key>Example-Object</Key>\n"
  <> " <ETag>\"3858f62230ac3c915f300c664312c11f-9\"</ETag>\n"
  <> "</CompleteMultipartUploadResult>"
}

fn complete_error_response() -> String {
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\n"
  <> "<Error>\n"
  <> " <Code>InternalError</Code>\n"
  <> " <Message>We encountered an internal error. Please try again.</Message>\n"
  <> " <RequestId>656c76696e6727732072657175657374</RequestId>\n"
  <> " <HostId>Uuag1LuByRx9e6j5Onimru9pO4ZVKnJ2Qz7/C1NPcfTWAtRPfTaOFg==</HostId>\n"
  <> "</Error>"
}

pub fn extracts_upload_id_from_aws_response_test() {
  assert xml.element_text(initiate_response(), "UploadId")
    == Ok("VXBsb2FkIElEIGZvciA2aWWpbmcncyBteS1tb3ZpZS5tMnRzIHVwbG9hZA")
}

pub fn extracts_etag_from_aws_response_test() {
  assert xml.element_text(complete_response(), "ETag")
    == Ok("\"3858f62230ac3c915f300c664312c11f-9\"")
}

pub fn detects_aws_200_status_complete_error_test() {
  assert xml.error_code(complete_error_response()) == Ok("InternalError")
  assert xml.error_code(complete_response()) == Error(Nil)
}

pub fn extracts_first_element_test() {
  assert xml.element_text("<Code>First</Code><Code>Second</Code>", "Code")
    == Ok("First")
}

pub fn decodes_five_xml_entities_test() {
  assert xml.element_text("<Value>&amp;&lt;&gt;&quot;&apos;</Value>", "Value")
    == Ok("&<>\"'")
}

pub fn reports_missing_element_test() {
  assert xml.element_text(initiate_response(), "ETag")
    == Error(xml.ElementMissing("ETag"))
}

pub fn reports_unterminated_element_test() {
  assert xml.element_text("<Code>InternalError", "Code")
    == Error(xml.UnterminatedElement("Code"))
}

pub fn rejects_unknown_entity_test() {
  assert xml.element_text("<Code>&nbsp;</Code>", "Code")
    == Error(xml.UnknownEntity("nbsp"))
}

pub fn rejects_malformed_entities_test() {
  assert xml.element_text("<Code>&amp</Code>", "Code")
    == Error(xml.MalformedEntity("amp"))
  assert xml.element_text("<Code>&;</Code>", "Code")
    == Error(xml.MalformedEntity(""))
}

pub fn error_code_stays_within_error_element_test() {
  assert xml.error_code(
      "<Code>Outside</Code><Error><Message>failed</Message></Error>",
    )
    == Error(Nil)
}
