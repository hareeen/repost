import gleam/list
import gleam/result
import gleam/string

pub type XmlError {
  ElementMissing(tag: String)
  UnterminatedElement(tag: String)
  MalformedEntity(entity: String)
  UnknownEntity(entity: String)
}

pub fn element_text(xml: String, tag: String) -> Result(String, XmlError) {
  let opening = "<" <> tag <> ">"
  let closing = "</" <> tag <> ">"
  case string.split_once(xml, opening) {
    Error(_) -> Error(ElementMissing(tag))
    Ok(#(_, after_opening)) ->
      case string.split_once(after_opening, closing) {
        Error(_) -> Error(UnterminatedElement(tag))
        Ok(#(content, _)) -> decode_entities(content)
      }
  }
}

pub fn error_code(xml: String) -> Result(String, Nil) {
  case string.split_once(xml, "<Error>") {
    Error(_) -> Error(Nil)
    Ok(#(_, after_opening)) ->
      case string.split_once(after_opening, "</Error>") {
        Error(_) -> Error(Nil)
        Ok(#(error_body, _)) ->
          case element_text(error_body, "Code") {
            Ok(code) -> Ok(code)
            Error(_) -> Error(Nil)
          }
      }
  }
}

fn decode_entities(content: String) -> Result(String, XmlError) {
  case string.split(content, "&") {
    [] -> Ok("")
    [prefix, ..entities] -> {
      use decoded <- result.try(list.try_map(entities, decode_entity))
      Ok(string.concat([prefix, ..decoded]))
    }
  }
}

fn decode_entity(fragment: String) -> Result(String, XmlError) {
  case string.split_once(fragment, ";") {
    Error(_) -> Error(MalformedEntity(fragment))
    Ok(#(entity, suffix)) -> {
      let decoded = case entity {
        "amp" -> Ok("&")
        "lt" -> Ok("<")
        "gt" -> Ok(">")
        "quot" -> Ok("\"")
        "apos" -> Ok("'")
        "" -> Error(MalformedEntity(entity))
        _ -> Error(UnknownEntity(entity))
      }
      case decoded {
        Ok(value) -> Ok(value <> suffix)
        Error(error) -> Error(error)
      }
    }
  }
}
