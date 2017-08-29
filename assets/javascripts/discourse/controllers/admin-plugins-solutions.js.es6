import Ember from "ember";
import { ajax } from 'discourse/lib/ajax';

function genericError() {
  bootbox.alert(I18n.t('generic_error'));
}

export default Ember.Controller.extend({
  sortedPosts: Ember.computed.sort('model', 'postSorting'),
  postSorting: ['id:desc'],
  performingAction: false,
  findAll() {
    let self = this;
    this.set("performingAction", true);
    ajax("/solution/index.json").then(result => {
      self.set("model", result);
    }).catch(genericError).finally(() => {
      self.set("performingAction", false);
    });
  },
  proc(act, post) {
    let self = this;
    this.set("performingAction", true);
    ajax(`/solution/${act}`, {
      type: "POST",
      data: {id: post.id}
    }).then(() => {
      self.get("model").removeObject(post);
    }).catch(genericError).finally(() => {
      self.set("performingAction", false);
    });
  },
  actions: {
    refresh() {
      this.findAll();
    },
    accept(post) {
      this.proc("accept", post);
    },
    reject(post) {
      this.proc("reject", post);
    }
  }
});