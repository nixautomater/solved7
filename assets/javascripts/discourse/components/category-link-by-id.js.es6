import { default as computed, observes } from 'ember-addons/ember-computed-decorators';

export default Ember.Component.extend({
  @computed("category_id")
  category(category_id) {
    return this.site.categories.findBy("id", category_id);
  }
});