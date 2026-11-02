/*
 * Copyright (C) 2026 DinoX
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

using Gee;
using Xmpp;

namespace Xmpp.Xep.References {

    public const string NS_URI = "urn:xmpp:reference:0";

    public class Reference : Object {
        public string type_ { get; set; }
        public string? uri { get; set; }
        public string? begin { get; set; }
        public string? end { get; set; }
    }

    public static Gee.List<Reference> get_references(MessageStanza message) {
        var results = new ArrayList<Reference>();
        foreach (StanzaNode node in message.stanza.get_all_subnodes()) {
            if (node.ns_uri == NS_URI && node.name == "reference") {
                string? type_ = node.get_attribute("type");
                if (type_ != null) {
                    var reference = new Reference();
                    reference.type_ = type_;
                    reference.uri = node.get_attribute("uri");
                    reference.begin = node.get_attribute("begin");
                    reference.end = node.get_attribute("end");
                    results.add(reference);
                }
            }
        }
        return results;
    }

    public static void add_reference(MessageStanza message, Reference reference) {
        var ref_node = new StanzaNode.build("reference", NS_URI).add_self_xmlns();
        ref_node.put_attribute("type", reference.type_);
        if (reference.uri != null) ref_node.put_attribute("uri", reference.uri);
        if (reference.begin != null) ref_node.put_attribute("begin", reference.begin);
        if (reference.end != null) ref_node.put_attribute("end", reference.end);
        message.stanza.put_node(ref_node);
    }
}
